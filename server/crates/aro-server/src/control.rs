use crate::http::AppState;
use anyhow::Result;
use chrono::Duration;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    task::JoinHandle,
};
use uuid::Uuid;

#[derive(Deserialize, Debug)]
#[serde(tag = "command", rename_all = "snake_case")]
enum ControlCommand {
    OpenPairing,
    PendingPairingRequests,
    Approve {
        request_id: Uuid,
        approve: bool,
        #[serde(default)]
        can_contribute: bool,
    },
    Devices,
    SetContribution {
        device_id: Uuid,
        allowed: bool,
    },
    RemoveTrack {
        content_hash: String,
    },
    Revoke {
        device_id: Uuid,
    },
    Import {
        path: PathBuf,
        #[serde(rename = "mode")]
        _mode: String,
    },
    Folders,
    ScanFolder {
        source_id: Option<Uuid>,
    },
    RemoveFolder {
        source_id: Uuid,
    },
    /// Enqueues one or more files for (re-)identification. Used for both "Sync Track
    /// Data" (one file) and "Sync Album Data" (every file in the album, resolved
    /// client-side — the server has no album grouping of its own). Keyed by content
    /// hash and absolute path rather than a track id: this server's `hub_track_id`s
    /// and the macOS app's own local library track ids are generated independently
    /// and never coincide, so content hash is the only identifier they share.
    IdentifyTracks {
        tracks: Vec<IdentifyTrackRequest>,
    },
    IdentificationStatus,
    /// Identification results recorded after `after` (exclusive), oldest first — the
    /// pull side the macOS app polls to merge results into its own local library
    /// catalog by content hash.
    IdentificationResults {
        after: i64,
        #[serde(default = "default_identification_results_limit")]
        limit: u32,
    },
    SetManualMetadata {
        request: ManualMetadataRequest,
    },
    SetSetting {
        key: String,
        value: Value,
    },
    Setting {
        key: String,
    },
    /// Reads a blob's bytes directly off this host's own store, base64-encoded
    /// into the JSON response. Exists for the macOS app running *this same*
    /// hub locally: it already reaches this socket for identification
    /// results, so cached artwork (see `IdentificationResults.artwork_url`,
    /// which points at `/v1/blobs/{hash}` since `aro-track-id` started
    /// caching Cover Art Archive images) is one local round-trip away without
    /// needing the HTTP layer's device/admin auth or a real network
    /// connection at all — appropriate here since this socket is already
    /// filesystem-permission-gated (0600) to the local user, unlike the HTTP
    /// blob endpoint which is reachable from other paired devices.
    Blob {
        hash: String,
    },
    /// Auto-generated playlists derived from this hub's canonical analytics (listening
    /// events, favourites, MusicBrainz mood tags) — see `crate::playlists`. Keyed by
    /// content hash; the macOS app maps hashes onto its local catalog and renders. The
    /// hub generates, clients never do. `utc_offset_minutes` (the caller's local UTC
    /// offset, positive east of UTC) scopes the Morning Rotation/Late Night playlists
    /// to *this* caller's timezone rather than the hub's.
    Playlists {
        #[serde(default)]
        utc_offset_minutes: i32,
    },
    /// Tier 3 "seed-track radio" (see `crate::playlists::radio`) — the tracks most
    /// similar to `content_hash` by measured audio-feature vector, nearest first,
    /// with the seed itself in front. `None`/empty result if the seed hasn't been
    /// analyzed yet.
    /// Reorders a queue by measured audio similarity — see
    /// `crate::playlists::smart_shuffle`.
    SmartShuffle {
        content_hashes: Vec<String>,
        #[serde(default)]
        start: Option<String>,
    },
    Radio {
        content_hash: String,
        #[serde(default = "default_radio_limit")]
        limit: usize,
    },
    /// Pulls this hub's own operation log, oldest-first after `after_sequence` —
    /// the local-profile analogue of `/v1/exchange`'s pull side, for a
    /// same-machine client replicating its library from its own hub instead of
    /// scanning independently. Unlike `/v1/exchange`, this needs no device
    /// credential or pairing: the control socket is already filesystem-permission
    /// gated to the local user, and a hub never needs to authenticate to itself.
    ChangesAfter {
        after_sequence: u64,
        #[serde(default = "default_changes_after_limit")]
        limit: u32,
    },
    /// Appends device-authored mutations from this Mac's durable outbox. This is
    /// the local-socket counterpart to the HTTPS exchange upload path; keeping it
    /// separate from catalogue replication lets the GUI remain an offline-capable
    /// client of its own hub rather than silently retaining favourites/history only
    /// in its private replica.
    PushOperations {
        operations: Vec<aro_sync_protocol::Operation>,
    },
    Catalog {
        #[serde(default)]
        cursor: u64,
        #[serde(default = "default_catalog_limit")]
        limit: u32,
        #[serde(default)]
        q: Option<String>,
        #[serde(default)]
        sort: Option<String>,
    },
    /// Resolves a content hash to its on-disk path so a same-machine client can
    /// open the file directly for playback, instead of reading its bytes through
    /// the socket the way `Blob` does (appropriate for artwork, not for streaming
    /// an entire song into memory first).
    TrackLocation {
        hash: String,
    },
    /// Reads a single config field by dotted key (e.g. `dashboard.bind`) — the
    /// control-socket analogue of `aro-server config get`, so callers on this
    /// machine (the macOS app's Settings UI) never hand-write `aro.toml`.
    GetConfig {
        key: String,
    },
    /// Writes a single config field and persists it, same validation as the
    /// CLI's `config set`. Never applies live — every field is only read at
    /// `serve()` startup, so the caller must restart the server to apply it.
    SetConfig {
        key: String,
        value: String,
    },
    /// Verifies every blob's bytes still hash to the content hash the store
    /// recorded for it — the control-socket analogue of `aro-server verify`,
    /// runnable against the live store without stopping the server (unlike
    /// `migrate`, which needs the exclusive instance lock).
    Verify,
    /// Deletes an unreferenced blob (one no track points at) by content hash —
    /// the control-socket analogue of `aro-server purge`. Only reachable from a
    /// hash a prior `Verify` named, by convention of callers, not enforced here.
    Purge {
        hash: String,
    },
    Status,
}

fn default_changes_after_limit() -> u32 {
    500
}

fn default_radio_limit() -> usize {
    crate::playlists::RADIO_DEFAULT_LIMIT
}

fn default_catalog_limit() -> u32 {
    50
}

#[derive(Deserialize, Debug)]
struct IdentifyTrackRequest {
    content_hash: String,
    path: PathBuf,
}

fn default_identification_results_limit() -> u32 {
    200
}

#[derive(Serialize)]
struct ControlResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

const CONTROL_PROTOCOL_VERSION: u16 = 13;

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct ManualMetadataRequest {
    content_hashes: Vec<String>,
    #[serde(default)]
    fields: serde_json::Map<String, Value>,
    #[serde(default)]
    reset: bool,
}

pub(crate) fn apply_manual_metadata(
    state: &AppState,
    request: ManualMetadataRequest,
    device_id: Uuid,
) -> Result<usize> {
    const FIELDS: [&str; 7] = [
        "title",
        "artist",
        "album",
        "genre",
        "release_year",
        "track_number",
        "disc_number",
    ];
    let timestamp = aro_sync_protocol::HybridTimestamp {
        physical_millis: chrono::Utc::now().timestamp_millis(),
        logical: 0,
        device_id,
    };
    let mut operations = Vec::new();
    for hash in request.content_hashes {
        let Some(track_id) = state.store.track_id_for_hash(&hash)? else {
            continue;
        };
        let mut payload = serde_json::Map::new();
        if request.reset {
            for field in FIELDS {
                payload.insert(format!("manual_{field}_set"), Value::Bool(false));
            }
            payload.insert("manual_artwork_set".into(), Value::Bool(false));
        } else {
            for (field, value) in &request.fields {
                if FIELDS.contains(&field.as_str()) {
                    payload.insert(format!("manual_{field}"), value.clone());
                    payload.insert(format!("manual_{field}_set"), Value::Bool(true));
                }
            }
        }
        if payload.is_empty() {
            continue;
        }
        let field_versions = payload
            .keys()
            .map(|field| (field.clone(), timestamp.clone()))
            .collect();
        operations.push(aro_sync_protocol::Operation {
            operation_id: Uuid::new_v4(),
            device_id,
            entity_type: "track_state".into(),
            entity_id: track_id.to_string(),
            kind: if request.reset {
                "reset_metadata"
            } else {
                "set_metadata"
            }
            .into(),
            payload: Value::Object(payload),
            field_versions,
        });
    }
    let count = operations.len();
    state.store.append_operations(&operations)?;
    Ok(count)
}

pub async fn start(path: &Path, state: Arc<AppState>) -> Result<JoinHandle<()>> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    if path.exists() {
        tokio::fs::remove_file(path).await?;
    }
    let listener = UnixListener::bind(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).await?;
    }
    Ok(tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let state = state.clone();
            tokio::spawn(async move {
                if let Err(error) = respond(stream, state).await {
                    tracing::warn!(%error, "control socket request failed");
                }
            });
        }
    }))
}

/// A control-socket client (this app's own macOS helper connections) that connects
/// but never finishes sending its request would otherwise leak its `tokio::spawn`ed
/// task forever, blocked on `read_until` — this is the local-socket equivalent of an
/// HTTP request timeout.
const CONTROL_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

async fn respond(mut stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let started = std::time::Instant::now();
    let response = match handle(&mut stream, state).await {
        Ok(result) => ControlResponse {
            ok: true,
            result: Some(result),
            error: None,
        },
        Err(error) => {
            tracing::warn!(
                %error,
                elapsed_ms = started.elapsed().as_millis(),
                "control socket request rejected"
            );
            ControlResponse {
                ok: false,
                result: None,
                error: Some(error.to_string()),
            }
        }
    };
    tracing::debug!(
        ok = response.ok,
        elapsed_ms = started.elapsed().as_millis(),
        "control socket request handled"
    );
    stream.write_all(&serde_json::to_vec(&response)?).await?;
    stream.shutdown().await?;
    Ok(())
}

async fn handle(stream: &mut UnixStream, state: Arc<AppState>) -> Result<Value> {
    let mut request = Vec::new();
    {
        let mut reader = BufReader::new(stream);
        tokio::time::timeout(CONTROL_READ_TIMEOUT, reader.read_until(b'\n', &mut request))
            .await
            .map_err(|_| anyhow::anyhow!("control request timed out waiting for data"))??;
    }
    if request.len() > 64 * 1_024 {
        anyhow::bail!("control request too large");
    }
    let command: ControlCommand = serde_json::from_slice(&request)?;
    tracing::debug!(command = ?command, "control command received");
    let result = match command {
        ControlCommand::OpenPairing => {
            let code = state.pairing.open(Duration::minutes(5));
            json!({
                "code": code,
                "expires_in_seconds": 300
            })
        }
        ControlCommand::PendingPairingRequests => {
            serde_json::to_value(state.pairing.pending_requests())?
        }
        ControlCommand::Approve {
            request_id,
            approve,
            can_contribute,
        } => {
            let credential = state.pairing.approve(request_id, approve, can_contribute)?;
            if let Some(credential) = &credential {
                let summary = state
                    .pairing
                    .devices()
                    .into_iter()
                    .find(|device| device.device_id == credential.device_id)
                    .ok_or_else(|| anyhow::anyhow!("approved device missing"))?;
                state.store.save_device(&summary, &credential.credential)?;
            }
            serde_json::to_value(credential)?
        }
        ControlCommand::Devices => serde_json::to_value(state.store.devices()?)?,
        ControlCommand::SetContribution { device_id, allowed } => {
            let updated = state.store.set_device_contribution(device_id, allowed)?;
            json!({"updated": updated})
        }
        ControlCommand::RemoveTrack { content_hash } => {
            let removed = state.store.tombstone_by_hash(&content_hash, state.hub_id)?;
            json!({"removed": removed})
        }
        ControlCommand::Revoke { device_id } => {
            let revoked = state.store.revoke_device(device_id)?;
            state.pairing.revoke(device_id);
            json!({"revoked": revoked})
        }
        ControlCommand::Import { path, _mode: _ } => {
            let sources = state.sources.clone();
            let folder = tokio::task::spawn_blocking(move || sources.add(&path)).await??;
            json!({
                "imported_songs": folder.song_count,
                "imported_tracks": folder.song_count,
                "source_id": folder.source_id
            })
        }
        ControlCommand::Folders => serde_json::to_value(state.sources.list()?)?,
        ControlCommand::ScanFolder { source_id } => {
            let sources = state.sources.clone();
            let changed = tokio::task::spawn_blocking(move || match source_id {
                Some(id) => sources.scan(id),
                None => {
                    sources.scan_all()?;
                    Ok(0)
                }
            })
            .await??;
            json!({"changed_songs": changed})
        }
        ControlCommand::RemoveFolder { source_id } => {
            json!({"removed": state.sources.remove(source_id)?})
        }
        ControlCommand::IdentifyTracks { tracks } => {
            let identification = state.sources.identification();
            for track in &tracks {
                identification.enqueue(track.content_hash.clone(), track.path.clone());
            }
            json!({"queued": tracks.len()})
        }
        ControlCommand::IdentificationStatus => {
            serde_json::to_value(state.sources.identification().status().await)?
        }
        ControlCommand::IdentificationResults { after, limit } => {
            serde_json::to_value(state.store.identification_results_since(after, limit)?)?
        }
        ControlCommand::SetManualMetadata { request } => json!({
            "updated": apply_manual_metadata(&state, request, state.hub_id)?
        }),
        ControlCommand::SetSetting { key, value } => {
            state.store.set_setting(&key, &value)?;
            json!({"ok": true})
        }
        ControlCommand::Setting { key } => json!({"value": state.store.setting(&key)?}),
        ControlCommand::Blob { hash } => {
            let path = state
                .store
                .blob_path_for_download(&hash)?
                .ok_or_else(|| anyhow::anyhow!("blob not found"))?;
            let bytes = tokio::fs::read(&path).await?;
            json!({
                "data_base64": base64::Engine::encode(
                    &base64::engine::general_purpose::STANDARD,
                    bytes
                )
            })
        }
        ControlCommand::Playlists { utc_offset_minutes } => {
            let store = state.store.clone();
            let seeds = tokio::task::spawn_blocking(move || store.playlist_seeds()).await??;
            serde_json::to_value(crate::playlists::generate(
                &seeds,
                chrono::Utc::now(),
                utc_offset_minutes,
            ))?
        }
        ControlCommand::SmartShuffle {
            content_hashes,
            start,
        } => serde_json::to_value(crate::playlists::smart_shuffle(
            &state.store.playlist_seeds()?,
            &content_hashes,
            start.as_deref(),
        ))?,
        ControlCommand::Radio {
            content_hash,
            limit,
        } => {
            let store = state.store.clone();
            let seeds = tokio::task::spawn_blocking(move || store.playlist_seeds()).await??;
            serde_json::to_value(crate::playlists::radio(&seeds, &content_hash, limit))?
        }
        ControlCommand::ChangesAfter {
            after_sequence,
            limit,
        } => serde_json::to_value(state.store.changes_after(after_sequence, limit)?)?,
        ControlCommand::PushOperations { operations } => {
            let accepted: Vec<Uuid> = operations
                .iter()
                .map(|operation| operation.operation_id)
                .collect();
            state.store.append_operations(&operations)?;
            json!({"accepted": accepted})
        }
        ControlCommand::Catalog {
            cursor,
            limit,
            q,
            sort,
        } => serde_json::to_value(state.store.catalog_page(
            cursor,
            limit,
            q.as_deref(),
            sort.as_deref(),
        )?)?,
        ControlCommand::TrackLocation { hash } => {
            let path = state
                .store
                .blob_path_for_download(&hash)?
                .ok_or_else(|| anyhow::anyhow!("track not found"))?;
            json!({"path": path})
        }
        ControlCommand::GetConfig { key } => {
            let config = crate::config::Config::load(&state.config_path)?;
            let value = serde_json::to_value(&config)?;
            let field = key
                .split('.')
                .try_fold(&value, |current, part| current.get(part))
                .ok_or_else(|| anyhow::anyhow!("unknown config field: {key}"))?;
            json!({"value": field})
        }
        ControlCommand::SetConfig { key, value } => {
            let mut config = crate::config::Config::load(&state.config_path)?;
            config.set_field(&key, &value)?;
            config.save(&state.config_path)?;
            json!({"ok": true, "restart_required": true})
        }
        ControlCommand::Verify => {
            let store = state.store.clone();
            let (count, failures) =
                tokio::task::spawn_blocking(move || store.verify_all()).await??;
            json!({"verified": count, "failures": failures})
        }
        ControlCommand::Purge { hash } => {
            let store = state.store.clone();
            let removed = tokio::task::spawn_blocking(move || store.purge_blob(&hash)).await??;
            json!({"removed": removed})
        }
        ControlCommand::Status => json!({
            "control_protocol_version": CONTROL_PROTOCOL_VERSION,
            "hub_id": state.hub_id,
            "display_name": state.display_name,
            "tls_fingerprint": state.tls_fingerprint,
            "https_port": state.https_port,
            "sequence": state.store.latest_sequence()?,
            "pairing_available": state.pairing.is_open()
            ,"storage_mode": state.sources.mode().as_str()
        }),
    };
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{config::Config, config::StorageMode, sources::SourceManager};
    use aro_sync_store::HubStore;
    use aro_track_id::{
        IdentificationQueue, audio_features::AudioFeatureQueue, loudness::LoudnessQueue,
    };

    async fn test_state() -> (Arc<AppState>, tempfile::TempDir) {
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
        config.data_dir = data_dir;
        config.hub_id = hub_id;
        let config_path = root.path().join("aro.toml");
        config.save(&config_path).unwrap();

        let state = Arc::new(AppState {
            config_path,
            hub_id,
            display_name: "Test Hub".into(),
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
            musicbrainz: Arc::new(aro_track_id::musicbrainz::MusicBrainzClient::new(
                "Aro/test".into(),
            )),
            artwork_http: reqwest::Client::new(),
        });
        (state, root)
    }

    async fn dispatch(state: &Arc<AppState>, command: Value) -> Result<Value> {
        let (mut client, mut server) = UnixStream::pair()?;
        let mut request = serde_json::to_vec(&command)?;
        request.push(b'\n');
        client.write_all(&request).await?;
        client.shutdown().await?;
        handle(&mut server, state.clone()).await
    }

    #[tokio::test]
    async fn changes_after_returns_operations_past_the_given_sequence() {
        let (state, _root) = test_state().await;
        let source = tempfile::tempdir().unwrap();
        std::fs::write(source.path().join("Song.flac"), b"audio").unwrap();
        state.sources.add(source.path()).unwrap();

        let all = dispatch(
            &state,
            json!({"command": "changes_after", "after_sequence": 0}),
        )
        .await
        .unwrap();
        let all = all.as_array().unwrap();
        assert!(!all.is_empty());

        let latest_sequence = state.store.latest_sequence().unwrap();
        let none = dispatch(
            &state,
            json!({
                "command": "changes_after",
                "after_sequence": latest_sequence
            }),
        )
        .await
        .unwrap();
        assert!(none.as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn status_bootstraps_the_pinned_https_endpoint() {
        let (state, _root) = test_state().await;

        let result = dispatch(&state, json!({"command": "status"}))
            .await
            .unwrap();

        assert_eq!(result["control_protocol_version"], CONTROL_PROTOCOL_VERSION);
        assert_eq!(result["hub_id"], state.hub_id.to_string());
        assert_eq!(result["tls_fingerprint"], "test-fingerprint");
        assert_eq!(result["https_port"], 4848);
    }

    #[tokio::test]
    async fn push_operations_materializes_offline_device_intent() {
        let (state, _root) = test_state().await;
        let source = tempfile::tempdir().unwrap();
        std::fs::write(source.path().join("Song.flac"), b"audio").unwrap();
        state.sources.add(source.path()).unwrap();
        let hash = state
            .store
            .content_hashes()
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        let track_id = state.store.track_id_for_hash(&hash).unwrap().unwrap();
        let operation_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();

        let result = dispatch(
            &state,
            json!({
                "command": "push_operations",
                "operations": [{
                    "operation_id": operation_id,
                    "device_id": device_id,
                    "entity_type": "track_state",
                    "entity_id": track_id,
                    "kind": "favourite",
                    "payload": {"favourite": true},
                    "field_versions": {
                        "favourite": {
                            "physical_millis": 1,
                            "logical": 0,
                            "device_id": device_id
                        }
                    }
                }]
            }),
        )
        .await
        .unwrap();

        assert_eq!(result["accepted"][0], operation_id.to_string());
        assert!(state.store.catalog_page(0, 10, None, None).unwrap().tracks[0].favourite);
    }

    #[tokio::test]
    async fn track_location_resolves_a_managed_import_to_its_blob_path() {
        let (state, _root) = test_state().await;
        let source = tempfile::tempdir().unwrap();
        let song = source.path().join("Song.flac");
        std::fs::write(&song, b"audio").unwrap();
        state.sources.add(source.path()).unwrap();
        let hash = state
            .store
            .content_hashes()
            .unwrap()
            .into_iter()
            .next()
            .unwrap();

        let result = dispatch(&state, json!({"command": "track_location", "hash": hash}))
            .await
            .unwrap();
        let path = result["path"].as_str().unwrap();
        assert!(std::path::Path::new(path).is_file());
    }

    #[tokio::test]
    async fn track_location_rejects_an_unknown_hash() {
        let (state, _root) = test_state().await;
        let result = dispatch(
            &state,
            json!({"command": "track_location", "hash": "0".repeat(64)}),
        )
        .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn get_and_set_config_round_trip_through_the_file() {
        let (state, _root) = test_state().await;

        dispatch(
            &state,
            json!({
                "command": "set_config",
                "key": "display_name",
                "value": "Living Room"
            }),
        )
        .await
        .unwrap();

        let result = dispatch(
            &state,
            json!({"command": "get_config", "key": "display_name"}),
        )
        .await
        .unwrap();
        assert_eq!(result["value"].as_str().unwrap(), "Living Room");
    }

    #[tokio::test]
    async fn set_config_rejects_storage_mode() {
        let (state, _root) = test_state().await;
        let result = dispatch(
            &state,
            json!({
                "command": "set_config",
                "key": "storage_mode",
                "value": "referenced"
            }),
        )
        .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn verify_reports_a_deleted_blob_as_a_failure() {
        let (state, _root) = test_state().await;
        let source = tempfile::tempdir().unwrap();
        std::fs::write(source.path().join("Song.flac"), b"audio").unwrap();
        state.sources.add(source.path()).unwrap();
        let hash = state
            .store
            .content_hashes()
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        let path = state.store.blob_path_for_download(&hash).unwrap().unwrap();
        std::fs::remove_file(&path).unwrap();

        let result = dispatch(&state, json!({"command": "verify"}))
            .await
            .unwrap();
        let failures = result["failures"].as_array().unwrap();
        assert!(
            failures
                .iter()
                .any(|value| value.as_str() == Some(hash.as_str()))
        );
    }

    #[tokio::test]
    async fn purge_reports_whether_a_blob_existed() {
        let (state, _root) = test_state().await;
        let missing = dispatch(&state, json!({"command": "purge", "hash": "0".repeat(64)}))
            .await
            .unwrap();
        assert_eq!(missing["removed"], json!(false));
    }
}
