//! Optional DLNA media server (UPnP MediaServer:1) — exposes the library to TVs,
//! receivers, and UPnP apps over plain HTTP, alongside (never instead of) the
//! authenticated sync API. Discovery is SSDP (`ssdp` module); browsing is
//! ContentDirectory DIDL-Lite over a cached snapshot of the export manifest; audio
//! is served by content hash reusing the sync API's Range streaming.
//!
//! DLNA has no authentication, so this whole listener is disabled by default and
//! guarded to private/loopback peers (`lan_only`), mirroring the config's
//! LAN-only bind validation.

pub mod connection_manager;
pub mod content_directory;
pub mod description;
pub mod didl;
pub mod media;
pub mod mime;
pub mod ssdp;

use crate::{config::Config, http::AppState, playlists::GeneratedPlaylist};
use anyhow::{Context, Result};
use axum::{
    Router,
    extract::{ConnectInfo, Request, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{any, get, post},
};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::Arc,
};
use uuid::Uuid;

pub struct DlnaState {
    pub app: AppState,
    pub friendly_name: String,
    snapshot: parking_lot::Mutex<Option<(u64, Arc<Snapshot>)>>,
}

#[derive(Clone, Debug)]
pub struct SnapshotTrack {
    pub track_id: Uuid,
    pub content_hash: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    /// Original file extension, lowercased — drives MIME/DLNA headers.
    pub extension: String,
    pub byte_count: u64,
}

pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub tracks: Vec<Arc<SnapshotTrack>>,
}

pub struct Artist {
    pub id: String,
    pub name: String,
    /// Indexes into [`Snapshot::albums`].
    pub albums: Vec<usize>,
    /// Tracks with no album tag, listed directly under the artist container.
    pub loose_tracks: Vec<Arc<SnapshotTrack>>,
}

/// An immutable browse tree built from one pass over the export manifest, shared
/// by every request until the operation log advances.
pub struct Snapshot {
    pub tracks: Vec<Arc<SnapshotTrack>>,
    pub artists: Vec<Artist>,
    pub albums: Vec<Album>,
    by_hash: HashMap<String, Arc<SnapshotTrack>>,
    by_id: HashMap<Uuid, Arc<SnapshotTrack>>,
}

pub struct Listing {
    /// Concatenated DIDL entries, not yet wrapped in the DIDL-Lite envelope.
    pub entries: String,
    pub returned: usize,
    pub total: usize,
}

pub enum BrowseError {
    NoSuchObject,
    Internal,
}

/// First 16 hex chars of SHA-256 — stable synthetic container ids for names that
/// have no natural identifier. Browse resolves them by recomputing, never by a
/// reverse table.
fn name_hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))[..16].to_string()
}

fn artist_container_id(name: &str) -> String {
    format!("artist:{}", name_hash(name))
}

fn album_container_id(artist: &str, album: &str) -> String {
    format!("album:{}", name_hash(&format!("{artist}\u{0}{album}")))
}

impl Snapshot {
    fn build(tracks: Vec<SnapshotTrack>) -> Self {
        let mut all: Vec<Arc<SnapshotTrack>> = tracks.into_iter().map(Arc::new).collect();
        all.sort_by_cached_key(|track| track.title.to_lowercase());

        let mut by_hash = HashMap::new();
        let mut by_id = HashMap::new();
        for track in &all {
            by_hash.insert(track.content_hash.clone(), track.clone());
            by_id.insert(track.track_id, track.clone());
        }

        let mut artist_names: Vec<String> = all.iter().map(|track| track.artist.clone()).collect();
        artist_names.sort_by_cached_key(|name| name.to_lowercase());
        artist_names.dedup();

        let mut albums: Vec<Album> = Vec::new();
        let mut artists: Vec<Artist> = Vec::new();
        for name in artist_names {
            let mut artist_tracks: Vec<Arc<SnapshotTrack>> = all
                .iter()
                .filter(|track| track.artist == name)
                .cloned()
                .collect();
            artist_tracks.sort_by_cached_key(|track| {
                (
                    track.disc_number.unwrap_or(0),
                    track.track_number.unwrap_or(0),
                    track.title.to_lowercase(),
                )
            });
            let mut album_titles: Vec<String> = artist_tracks
                .iter()
                .filter_map(|track| track.album.clone())
                .collect();
            album_titles.sort_by_cached_key(|title| title.to_lowercase());
            album_titles.dedup();
            let mut album_indexes = Vec::new();
            for title in album_titles {
                let album_tracks: Vec<Arc<SnapshotTrack>> = artist_tracks
                    .iter()
                    .filter(|track| track.album.as_deref() == Some(title.as_str()))
                    .cloned()
                    .collect();
                album_indexes.push(albums.len());
                albums.push(Album {
                    id: album_container_id(&name, &title),
                    title,
                    artist: name.clone(),
                    tracks: album_tracks,
                });
            }
            let loose_tracks = artist_tracks
                .iter()
                .filter(|track| track.album.is_none())
                .cloned()
                .collect();
            artists.push(Artist {
                id: artist_container_id(&name),
                name,
                albums: album_indexes,
                loose_tracks,
            });
        }

        Self {
            tracks: all,
            artists,
            albums,
            by_hash,
            by_id,
        }
    }

    pub fn track_by_hash(&self, content_hash: &str) -> Option<&Arc<SnapshotTrack>> {
        self.by_hash.get(content_hash)
    }
}

impl DlnaState {
    pub fn new(app: AppState, config: &Config) -> Self {
        let friendly_name = if config.dlna.friendly_name.is_empty() {
            config.display_name.clone()
        } else {
            config.dlna.friendly_name.clone()
        };
        Self {
            app,
            friendly_name,
            snapshot: parking_lot::Mutex::new(None),
        }
    }

    /// The current browse tree, rebuilt only when the operation log has advanced
    /// past the cached sequence.
    pub async fn snapshot(&self) -> Result<Arc<Snapshot>, BrowseError> {
        let cached = self.snapshot.lock().clone();
        let store = self.app.store.clone();
        let display_name = self.app.display_name.clone();
        let cached_sequence = cached.as_ref().map(|(sequence, _)| *sequence);
        let fresh = tokio::task::spawn_blocking(move || {
            let sequence = store.latest_sequence()?;
            if Some(sequence) == cached_sequence {
                return Ok::<_, aro_sync_store::StoreError>((sequence, None));
            }
            let manifest = store.export_manifest(&display_name)?;
            Ok((sequence, Some(manifest)))
        })
        .await
        .map_err(|_| BrowseError::Internal)?
        .map_err(|error| {
            tracing::warn!(%error, "DLNA snapshot rebuild failed");
            BrowseError::Internal
        })?;
        match fresh {
            (_, None) => Ok(cached.expect("cache hit implies cached snapshot").1),
            (sequence, Some(manifest)) => {
                let tracks = manifest
                    .tracks
                    .into_iter()
                    .filter(|track| track.removed_at.is_none())
                    .map(|track| SnapshotTrack {
                        track_id: track.track_id,
                        content_hash: track.content_hash,
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        track_number: track.track_number,
                        disc_number: track.disc_number,
                        extension: track.original_extension.to_lowercase(),
                        byte_count: track.byte_count,
                    })
                    .collect();
                let snapshot = Arc::new(Snapshot::build(tracks));
                *self.snapshot.lock() = Some((sequence, snapshot.clone()));
                Ok(snapshot)
            }
        }
    }

    /// SystemUpdateID for renderers: the operation log's max sequence, which
    /// advances on every library mutation and is exactly the snapshot cache key —
    /// the reported id and the served tree change together.
    pub async fn system_update_id(&self) -> u32 {
        let store = self.app.store.clone();
        tokio::task::spawn_blocking(move || store.latest_sequence())
            .await
            .ok()
            .and_then(|result| result.ok())
            .unwrap_or(0) as u32
    }

    async fn generated_playlists(&self) -> Result<Vec<GeneratedPlaylist>, BrowseError> {
        let store = self.app.store.clone();
        let seeds = tokio::task::spawn_blocking(move || store.playlist_seeds())
            .await
            .map_err(|_| BrowseError::Internal)?
            .map_err(|error| {
                tracing::warn!(%error, "DLNA playlist seeds failed");
                BrowseError::Internal
            })?;
        // DLNA browsing has no per-client timezone context (UPnP carries none), so
        // Morning Rotation/Late Night fall back to UTC framing here.
        Ok(crate::playlists::generate(&seeds, chrono::Utc::now(), 0))
    }

    pub async fn browse_children(
        &self,
        object_id: &str,
        starting_index: usize,
        requested_count: usize,
        media_base: &str,
    ) -> Result<Listing, BrowseError> {
        let snapshot = self.snapshot().await?;
        let entries: Vec<String> = match object_id {
            "0" => {
                let playlists = self.generated_playlists().await?;
                vec![
                    didl::container(
                        "music:artists",
                        "0",
                        "Artists",
                        "object.container",
                        snapshot.artists.len(),
                    ),
                    didl::container(
                        "music:albums",
                        "0",
                        "Albums",
                        "object.container",
                        snapshot.albums.len(),
                    ),
                    didl::container(
                        "music:tracks",
                        "0",
                        "All Tracks",
                        "object.container",
                        snapshot.tracks.len(),
                    ),
                    didl::container(
                        "music:playlists",
                        "0",
                        "Playlists",
                        "object.container",
                        playlists.len(),
                    ),
                ]
            }
            "music:artists" => snapshot
                .artists
                .iter()
                .map(|artist| {
                    didl::container(
                        &artist.id,
                        "music:artists",
                        &artist.name,
                        "object.container.person.musicArtist",
                        artist.albums.len() + artist.loose_tracks.len(),
                    )
                })
                .collect(),
            "music:albums" => snapshot
                .albums
                .iter()
                .map(|album| {
                    didl::album_container(
                        &album.id,
                        "music:albums",
                        &album.title,
                        &album.artist,
                        album.tracks.len(),
                    )
                })
                .collect(),
            "music:tracks" => snapshot
                .tracks
                .iter()
                .map(|track| didl::track_item(track, "music:tracks", media_base))
                .collect(),
            "music:playlists" => {
                let playlists = self.generated_playlists().await?;
                playlists
                    .iter()
                    .map(|playlist| {
                        let resolvable = playlist
                            .content_hashes
                            .iter()
                            .filter(|hash| snapshot.track_by_hash(hash).is_some())
                            .count();
                        didl::playlist_container(
                            &format!("playlist:{}", playlist.id),
                            "music:playlists",
                            &playlist.title,
                            &playlist.subtitle,
                            resolvable,
                        )
                    })
                    .collect()
            }
            id if id.starts_with("artist:") => {
                let artist = snapshot
                    .artists
                    .iter()
                    .find(|artist| artist.id == id)
                    .ok_or(BrowseError::NoSuchObject)?;
                artist
                    .albums
                    .iter()
                    .map(|&index| {
                        let album = &snapshot.albums[index];
                        didl::album_container(
                            &album.id,
                            id,
                            &album.title,
                            &album.artist,
                            album.tracks.len(),
                        )
                    })
                    .chain(
                        artist
                            .loose_tracks
                            .iter()
                            .map(|track| didl::track_item(track, id, media_base)),
                    )
                    .collect()
            }
            id if id.starts_with("album:") => {
                let album = snapshot
                    .albums
                    .iter()
                    .find(|album| album.id == id)
                    .ok_or(BrowseError::NoSuchObject)?;
                album
                    .tracks
                    .iter()
                    .map(|track| didl::track_item(track, id, media_base))
                    .collect()
            }
            id if id.starts_with("playlist:") => {
                let slug = &id["playlist:".len()..];
                let playlists = self.generated_playlists().await?;
                let playlist = playlists
                    .iter()
                    .find(|playlist| playlist.id == slug)
                    .ok_or(BrowseError::NoSuchObject)?;
                playlist
                    .content_hashes
                    .iter()
                    .filter_map(|hash| snapshot.track_by_hash(hash))
                    .map(|track| didl::track_item(track, id, media_base))
                    .collect()
            }
            // Browsing an item's children is a well-formed question with an
            // empty answer, not an error.
            id if id.starts_with("track:") => Vec::new(),
            _ => return Err(BrowseError::NoSuchObject),
        };

        let total = entries.len();
        let page: Vec<String> = entries
            .into_iter()
            .skip(starting_index)
            .take(if requested_count == 0 {
                usize::MAX
            } else {
                requested_count
            })
            .collect();
        Ok(Listing {
            returned: page.len(),
            total,
            entries: page.concat(),
        })
    }

    pub async fn browse_metadata(
        &self,
        object_id: &str,
        media_base: &str,
    ) -> Result<Listing, BrowseError> {
        let snapshot = self.snapshot().await?;
        let entry = match object_id {
            "0" => didl::container("0", "-1", &self.friendly_name, "object.container", 4),
            "music:artists" => didl::container(
                "music:artists",
                "0",
                "Artists",
                "object.container",
                snapshot.artists.len(),
            ),
            "music:albums" => didl::container(
                "music:albums",
                "0",
                "Albums",
                "object.container",
                snapshot.albums.len(),
            ),
            "music:tracks" => didl::container(
                "music:tracks",
                "0",
                "All Tracks",
                "object.container",
                snapshot.tracks.len(),
            ),
            "music:playlists" => {
                let playlists = self.generated_playlists().await?;
                didl::container(
                    "music:playlists",
                    "0",
                    "Playlists",
                    "object.container",
                    playlists.len(),
                )
            }
            id if id.starts_with("artist:") => {
                let artist = snapshot
                    .artists
                    .iter()
                    .find(|artist| artist.id == id)
                    .ok_or(BrowseError::NoSuchObject)?;
                didl::container(
                    id,
                    "music:artists",
                    &artist.name,
                    "object.container.person.musicArtist",
                    artist.albums.len() + artist.loose_tracks.len(),
                )
            }
            id if id.starts_with("album:") => {
                let album = snapshot
                    .albums
                    .iter()
                    .find(|album| album.id == id)
                    .ok_or(BrowseError::NoSuchObject)?;
                didl::album_container(
                    id,
                    "music:albums",
                    &album.title,
                    &album.artist,
                    album.tracks.len(),
                )
            }
            id if id.starts_with("playlist:") => {
                let slug = &id["playlist:".len()..];
                let playlists = self.generated_playlists().await?;
                let playlist = playlists
                    .iter()
                    .find(|playlist| playlist.id == slug)
                    .ok_or(BrowseError::NoSuchObject)?;
                let resolvable = playlist
                    .content_hashes
                    .iter()
                    .filter(|hash| snapshot.track_by_hash(hash).is_some())
                    .count();
                didl::playlist_container(
                    id,
                    "music:playlists",
                    &playlist.title,
                    &playlist.subtitle,
                    resolvable,
                )
            }
            id if id.starts_with("track:") => {
                let track_id: Uuid = id["track:".len()..]
                    .parse()
                    .map_err(|_| BrowseError::NoSuchObject)?;
                let track = snapshot
                    .by_id
                    .get(&track_id)
                    .ok_or(BrowseError::NoSuchObject)?;
                didl::track_item(track, "music:tracks", media_base)
            }
            _ => return Err(BrowseError::NoSuchObject),
        };
        Ok(Listing {
            entries: entry,
            returned: 1,
            total: 1,
        })
    }
}

pub fn router(state: Arc<DlnaState>) -> Router {
    Router::new()
        .route("/rootDesc.xml", get(root_description))
        .route(
            "/scpd/ContentDirectory.xml",
            get(|| async { xml_document(description::CONTENT_DIRECTORY_SCPD.to_string()) }),
        )
        .route(
            "/scpd/ConnectionManager.xml",
            get(|| async { xml_document(description::CONNECTION_MANAGER_SCPD.to_string()) }),
        )
        .route(
            "/control/ContentDirectory",
            post(content_directory::control),
        )
        .route(
            "/control/ConnectionManager",
            post(connection_manager::control),
        )
        .route("/events/{service}", any(gena))
        .route("/media/{content_hash}", get(media::media))
        .layer(middleware::from_fn(lan_only))
        .with_state(state)
}

async fn root_description(State(state): State<Arc<DlnaState>>) -> Response {
    xml_document(description::root_description(
        &state.friendly_name,
        state.app.hub_id,
    ))
}

fn xml_document(body: String) -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, r#"text/xml; charset="utf-8""#)],
        body,
    )
        .into_response()
}

/// Minimal GENA: subscriptions are accepted (renderers refuse to use services whose
/// event endpoint errors) but no NOTIFY callbacks are delivered — control points
/// poll `GetSystemUpdateID` for changes. `axum::routing::any` is used because
/// SUBSCRIBE/UNSUBSCRIBE are extension methods no standard route helper covers.
async fn gena(
    axum::extract::Path(_service): axum::extract::Path<String>,
    request: Request,
) -> Response {
    match request.method().as_str() {
        "SUBSCRIBE" => {
            let sid = format!("uuid:{}", Uuid::new_v4());
            (
                StatusCode::OK,
                [
                    (
                        header::HeaderName::from_static("sid"),
                        HeaderValue::from_str(&sid).expect("uuid is ascii"),
                    ),
                    (
                        header::HeaderName::from_static("timeout"),
                        HeaderValue::from_static("Second-1800"),
                    ),
                ],
            )
                .into_response()
        }
        "UNSUBSCRIBE" => StatusCode::OK.into_response(),
        _ => StatusCode::METHOD_NOT_ALLOWED.into_response(),
    }
}

/// Defense in depth for an unauthenticated listener: only private/loopback peers
/// are served, matching the LAN-only stance config enforces on every bind.
async fn lan_only(
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
    next: Next,
) -> Response {
    let allowed = match peer.ip() {
        IpAddr::V4(ip) => ip.is_private() || ip.is_loopback(),
        IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local(),
    };
    if !allowed {
        return StatusCode::FORBIDDEN.into_response();
    }
    next.run(request).await
}

/// Binds the HTTP listener and starts SSDP; returns task handles that keep both
/// alive for the life of `serve()`. SSDP failure (e.g. port 1900 contention that
/// SO_REUSEPORT could not resolve) logs and degrades to manual-URL access rather
/// than taking the server down.
pub async fn start(config: &Config, app: AppState) -> Result<Vec<tokio::task::JoinHandle<()>>> {
    let state = Arc::new(DlnaState::new(app, config));
    let listener = tokio::net::TcpListener::bind(config.dlna.bind)
        .await
        .with_context(|| format!("could not bind DLNA listener at {}", config.dlna.bind))?;
    tracing::warn!(
        address = %config.dlna.bind,
        "Unauthenticated DLNA media server enabled"
    );
    let http = tokio::spawn(async move {
        if let Err(error) = axum::serve(
            listener,
            router(state).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        {
            tracing::error!(%error, "DLNA listener stopped");
        }
    });
    let advertiser =
        ssdp::Advertiser::new(config.hub_id, config.dlna.bind, config.dlna.bind.port());
    let discovery = tokio::spawn(async move {
        if let Err(error) = ssdp::run(advertiser).await {
            tracing::error!(%error, "SSDP advertisement unavailable; DLNA reachable by URL only");
        }
    });
    Ok(vec![http, discovery])
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use crate::{config::StorageMode, sources::SourceManager};
    use aro_sync_protocol::{HybridTimestamp, Operation};
    use aro_sync_store::HubStore;
    use aro_track_id::{
        IdentificationQueue, audio_features::AudioFeatureQueue, loudness::LoudnessQueue,
    };

    async fn test_state() -> (Arc<DlnaState>, tempfile::TempDir) {
        let root = tempfile::tempdir().unwrap();
        let data_dir = root.path().join("Hub");
        let store = HubStore::open(&data_dir).unwrap();
        let hub_id = Uuid::new_v4();
        let identification = IdentificationQueue::start(store.clone(), hub_id, None);
        let loudness = LoudnessQueue::start(store.clone(), hub_id);
        let audio_features =
            AudioFeatureQueue::start(Arc::new(|_, _, _| Ok(())), Arc::new(|_, _, _| {}));
        let sources = SourceManager::start(
            store.clone(),
            hub_id,
            StorageMode::Managed,
            3_600,
            identification,
            loudness,
            audio_features,
        )
        .unwrap();
        let mut config = Config::default();
        config.hub_id = hub_id;
        config.display_name = "Test Hub".into();
        let app = AppState {
            config_path: root.path().join("aro.toml"),
            hub_id,
            display_name: config.display_name.clone(),
            tls_fingerprint: "test-fingerprint".into(),
            https_port: 4848,
            admin_token: config.admin_token.clone(),
            admin_allow: config.admin_allow.clone(),
            pairing: aro_sync_core::PairingManager::new("test-fingerprint".into()),
            jobs: aro_sync_core::JobRegistry::default(),
            store,
            sources,
            telemetry: crate::http::RuntimeTelemetry::default(),
            identification_available: false,
            musicbrainz_user_agent: "Aro/test".into(),
            musicbrainz: std::sync::Arc::new(aro_track_id::musicbrainz::MusicBrainzClient::new(
                "Aro/test".into(),
            )),
            artwork_http: reqwest::Client::new(),
        };
        (Arc::new(DlnaState::new(app, &config)), root)
    }

    fn seed_track(state: &DlnaState, directory: &std::path::Path, title: &str) -> String {
        let source = directory.join(format!("{title}.mp3"));
        std::fs::write(&source, format!("audio bytes of {title}")).unwrap();
        let (hash, size) = state.app.store.import_managed(&source).unwrap();
        let device_id = Uuid::new_v4();
        let version = HybridTimestamp {
            physical_millis: chrono::Utc::now().timestamp_millis(),
            logical: 0,
            device_id,
        };
        let payload = serde_json::json!({
            "content_hash": hash,
            "byte_count": size,
            "title": title,
            "artist": "Integration Artist",
            "album": "Integration Album",
            "original_filename": format!("{title}.mp3"),
            "original_extension": "mp3",
        });
        let field_versions = payload
            .as_object()
            .unwrap()
            .keys()
            .map(|field| (field.clone(), version.clone()))
            .collect();
        state
            .app
            .store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: Uuid::new_v4().to_string(),
                kind: "upsert".into(),
                payload,
                field_versions,
            }])
            .unwrap();
        hash
    }

    async fn serve_router(state: Arc<DlnaState>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(
                listener,
                router(state).into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
            .unwrap();
        });
        format!("http://{address}")
    }

    fn browse_body(object_id: &str) -> String {
        format!(
            r#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>{object_id}</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>0</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>"#
        )
    }

    #[tokio::test]
    async fn browse_and_stream_end_to_end() {
        let (state, root) = test_state().await;
        let hash = seed_track(&state, root.path(), "First Song");
        let base = serve_router(state).await;
        let client = reqwest::Client::new();

        let description = client
            .get(format!("{base}/rootDesc.xml"))
            .send()
            .await
            .unwrap();
        assert_eq!(description.status(), 200);
        let description = description.text().await.unwrap();
        assert!(description.contains("<friendlyName>Test Hub</friendlyName>"));

        let root_browse = client
            .post(format!("{base}/control/ContentDirectory"))
            .header(
                "SOAPACTION",
                r#""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#,
            )
            .body(browse_body("0"))
            .send()
            .await
            .unwrap();
        assert_eq!(root_browse.status(), 200);
        let root_browse = root_browse.text().await.unwrap();
        assert!(root_browse.contains("<TotalMatches>4</TotalMatches>"));
        assert!(root_browse.contains("music:artists"));
        assert!(root_browse.contains("music:playlists"));

        let tracks = client
            .post(format!("{base}/control/ContentDirectory"))
            .header(
                "SOAPACTION",
                r#""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#,
            )
            .body(browse_body("music:tracks"))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(tracks.contains("First Song"));
        assert!(tracks.contains("Integration Artist"));
        assert!(tracks.contains(&format!("/media/{hash}")));
        // DIDL is escaped inside the SOAP Result element.
        assert!(tracks.contains("&lt;DIDL-Lite"));

        let audio = client
            .get(format!("{base}/media/{hash}"))
            .header("Range", "bytes=0-4")
            .send()
            .await
            .unwrap();
        assert_eq!(audio.status(), 206);
        assert_eq!(
            audio.headers()["content-type"].to_str().unwrap(),
            "audio/mpeg"
        );
        assert!(
            audio.headers()["contentfeatures.dlna.org"]
                .to_str()
                .unwrap()
                .contains("DLNA.ORG_PN=MP3")
        );
        assert_eq!(
            audio.headers()["transfermode.dlna.org"].to_str().unwrap(),
            "Streaming"
        );
        assert_eq!(audio.bytes().await.unwrap().as_ref(), b"audio");

        let missing = client
            .get(format!("{base}/media/{}", "0".repeat(64)))
            .send()
            .await
            .unwrap();
        assert_eq!(missing.status(), 404);
    }

    #[tokio::test]
    async fn browse_unknown_object_faults_701() {
        let (state, _root) = test_state().await;
        let base = serve_router(state).await;
        let response = reqwest::Client::new()
            .post(format!("{base}/control/ContentDirectory"))
            .header(
                "SOAPACTION",
                r#""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#,
            )
            .body(browse_body("artist:doesnotexist"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 500);
        let body = response.text().await.unwrap();
        assert!(body.contains("<errorCode>701</errorCode>"));
    }

    #[tokio::test]
    async fn gena_subscribe_is_accepted() {
        let (state, _root) = test_state().await;
        let base = serve_router(state).await;
        let response = reqwest::Client::new()
            .request(
                reqwest::Method::from_bytes(b"SUBSCRIBE").unwrap(),
                format!("{base}/events/ContentDirectory"),
            )
            .header("CALLBACK", "<http://127.0.0.1:9/callback>")
            .header("NT", "upnp:event")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert!(
            response.headers()["sid"]
                .to_str()
                .unwrap()
                .starts_with("uuid:")
        );
        assert_eq!(response.headers()["timeout"], "Second-1800");
    }
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;

    fn track(title: &str, artist: &str, album: Option<&str>, number: Option<u32>) -> SnapshotTrack {
        SnapshotTrack {
            track_id: Uuid::new_v4(),
            content_hash: format!("hash-{title}"),
            title: title.into(),
            artist: artist.into(),
            album: album.map(Into::into),
            track_number: number,
            disc_number: Some(1),
            extension: "flac".into(),
            byte_count: 1,
        }
    }

    #[test]
    fn groups_artists_albums_and_loose_tracks() {
        let snapshot = Snapshot::build(vec![
            track("Zebra", "Beta Band", Some("Stripes"), Some(2)),
            track("Aardvark", "Beta Band", Some("Stripes"), Some(1)),
            track("Loose", "Beta Band", None, None),
            track("Solo", "Alpha", Some("One"), Some(1)),
        ]);

        assert_eq!(snapshot.artists.len(), 2);
        assert_eq!(snapshot.artists[0].name, "Alpha");
        assert_eq!(snapshot.artists[1].name, "Beta Band");
        let beta = &snapshot.artists[1];
        assert_eq!(beta.albums.len(), 1);
        assert_eq!(beta.loose_tracks.len(), 1);
        let stripes = &snapshot.albums[beta.albums[0]];
        assert_eq!(stripes.artist, "Beta Band");
        // Album tracks are in disc/track order, not title order.
        assert_eq!(stripes.tracks[0].title, "Aardvark");
        assert_eq!(stripes.tracks[1].title, "Zebra");
        // The flat list is title-sorted.
        assert_eq!(snapshot.tracks[0].title, "Aardvark");
        assert!(snapshot.track_by_hash("hash-Solo").is_some());
        assert!(snapshot.track_by_hash("missing").is_none());
    }

    #[test]
    fn container_ids_are_stable_and_distinct() {
        let first = artist_container_id("Radiohead");
        assert_eq!(first, artist_container_id("Radiohead"));
        assert_ne!(first, artist_container_id("radiohead"));
        assert_ne!(
            album_container_id("Radiohead", "OK"),
            album_container_id("Radio", "headOK"),
            "separator must keep artist/album boundaries distinct"
        );
    }
}
