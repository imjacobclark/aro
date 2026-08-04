use crate::{audio_metadata, sources::SourceManager};
use aro_sync_core::{JobRegistry, PairingError, PairingManager};
use aro_sync_protocol::*;
use aro_sync_store::{HubStore, StoreError};
use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{ConnectInfo, DefaultBodyLimit, Path, Query, Request, State},
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post, put},
};
use chrono::Duration;
use futures_util::Stream;
use ipnet::IpNet;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    net::{IpAddr, SocketAddr},
    path::{Component, Path as FilePath, PathBuf},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
};
use subtle::ConstantTimeEq;
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncSeekExt},
};
use tokio_util::io::ReaderStream;
use tower_governor::{GovernorLayer, governor::GovernorConfigBuilder};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    /// Path to the loaded `aro.toml`, kept for the control socket's
    /// `GetConfig`/`SetConfig` — those re-load, mutate, and save the file
    /// directly (same pattern as the CLI's `config get`/`set`) rather than
    /// keeping a second, driftable copy of `Config` in memory.
    pub config_path: PathBuf,
    pub hub_id: Uuid,
    pub display_name: String,
    /// Trust bootstrap exposed only through the filesystem-protected local
    /// control socket. Normal client traffic still uses pinned HTTPS.
    pub tls_fingerprint: String,
    pub https_port: u16,
    pub admin_token: String,
    /// Networks permitted to reach admin-only endpoints; enforced by
    /// [`admin_network_guard`] ahead of the per-request token check.
    pub admin_allow: Vec<IpNet>,
    pub pairing: PairingManager,
    pub jobs: JobRegistry,
    pub store: HubStore,
    pub sources: SourceManager,
    pub telemetry: RuntimeTelemetry,
    /// Whether an AcoustID key is configured, so `/v1/hub` can tell a client
    /// "no key is set" apart from "nothing's queued right now" without
    /// exposing the key itself.
    pub identification_available: bool,
    pub musicbrainz_user_agent: String,
    /// Shared so artwork discovery's many lookups queue behind one rate limiter.
    /// A per-request client would hold a per-request limiter and let concurrent
    /// pickers exceed MusicBrainz's one-request-a-second policy between them.
    pub musicbrainz: Arc<aro_track_id::musicbrainz::MusicBrainzClient>,
    pub artwork_http: reqwest::Client,
    /// Caps concurrent transcodes to what this machine can actually sustain.
    ///
    /// Encoding is CPU-bound and the hosts differ enormously: measured at 96 kbps, a
    /// 32-bit armv7 Raspberry Pi manages ~8× realtime on 4 cores while a 12-core laptop
    /// manages ~254×. Without a limit, `spawn_blocking`'s large default pool would happily
    /// start a transcode per request — unnoticeable on the laptop, and enough to thrash the
    /// Pi's cores and 917 MB of RAM. Sizing from the host's own parallelism keeps one core
    /// free to keep serving requests, and means neither machine is designed around the
    /// other's limits.
    pub transcode_slots: Arc<tokio::sync::Semaphore>,
}

/// Concurrent transcodes permitted, derived from the host rather than assumed.
pub fn default_transcode_slots() -> usize {
    std::thread::available_parallelism()
        .map(|value| value.get().saturating_sub(1).max(1))
        .unwrap_or(1)
}

#[derive(Clone, Default)]
pub struct RuntimeTelemetry {
    inner: Arc<RuntimeTelemetryInner>,
}

#[derive(Default)]
struct RuntimeTelemetryInner {
    active_transfers: AtomicU64,
    bytes_served: AtomicU64,
    completed_transfers: AtomicU64,
}

impl RuntimeTelemetry {
    pub fn active_transfers(&self) -> u64 {
        self.inner.active_transfers.load(Ordering::Relaxed)
    }

    pub fn bytes_served(&self) -> u64 {
        self.inner.bytes_served.load(Ordering::Relaxed)
    }

    pub fn completed_transfers(&self) -> u64 {
        self.inner.completed_transfers.load(Ordering::Relaxed)
    }

    fn track<S>(&self, stream: S) -> TrackedStream<S> {
        self.inner.active_transfers.fetch_add(1, Ordering::Relaxed);
        TrackedStream {
            inner: stream,
            telemetry: self.clone(),
        }
    }
}

struct TrackedStream<S> {
    inner: S,
    telemetry: RuntimeTelemetry,
}

impl<S, E> Stream for TrackedStream<S>
where
    S: Stream<Item = Result<Bytes, E>> + Unpin,
{
    type Item = Result<Bytes, E>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        match Pin::new(&mut self.inner).poll_next(cx) {
            Poll::Ready(Some(Ok(bytes))) => {
                self.telemetry
                    .inner
                    .bytes_served
                    .fetch_add(bytes.len() as u64, Ordering::Relaxed);
                Poll::Ready(Some(Ok(bytes)))
            }
            other => other,
        }
    }
}

impl<S> Drop for TrackedStream<S> {
    fn drop(&mut self) {
        self.telemetry
            .inner
            .active_transfers
            .fetch_sub(1, Ordering::Relaxed);
        self.telemetry
            .inner
            .completed_transfers
            .fetch_add(1, Ordering::Relaxed);
    }
}

fn is_peer_allowed(allow: &[IpNet], peer: IpAddr) -> bool {
    let normalized = match peer {
        IpAddr::V6(address) => address
            .to_ipv4_mapped()
            .map(IpAddr::V4)
            .unwrap_or(IpAddr::V6(address)),
        address => address,
    };
    allow
        .iter()
        .any(|net| net.contains(&peer) || net.contains(&normalized))
}

/// Rejects requests to admin-only routes whose peer address isn't covered by
/// `AppState::admin_allow`, before the handler's own token check runs.
async fn admin_network_guard(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
    next: Next,
) -> Response {
    if is_peer_allowed(&state.admin_allow, peer.ip()) {
        next.run(request).await
    } else {
        ApiError::forbidden(
            "admin_network_denied",
            "This network is not permitted to reach the admin API.",
        )
        .into_response()
    }
}

pub fn router(state: AppState) -> Router {
    let state = Arc::new(state);

    // Bursts of up to 8 requests, replenishing one every 500ms per source IP.
    // Defense-in-depth against admin-token brute forcing; the network guard
    // above and the token check itself are the primary controls.
    let admin_rate_limit = GovernorConfigBuilder::default()
        .finish()
        .expect("valid governor configuration");

    let admin_only = Router::new()
        .route("/v1/pairing/open", post(open_pairing))
        .route("/v1/pairing/approve", post(approve_pairing))
        .route("/v1/pairing/requests", get(pairing_requests))
        .route("/v1/admin/folders", get(folders).post(add_folder))
        .route("/v1/admin/folders/scan", post(scan_folders))
        .route("/v1/admin/folders/remove", post(remove_folder))
        .route("/v1/admin/folders/relocate", post(relocate_folder))
        .route("/v1/devices", get(devices))
        .route("/v1/devices/revoke", post(revoke))
        .route("/v1/devices/permissions", post(update_device_permissions))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            admin_network_guard,
        ))
        .layer(GovernorLayer::new(admin_rate_limit));

    let shared = Router::new()
        .route("/v1/hub", get(hub_info))
        .route("/v1/negotiate", post(negotiate))
        .route("/v1/pairing/start", post(start_pairing))
        .route("/v1/pairing/{id}/pake1", post(pairing_pake1))
        .route("/v1/pairing/{id}/confirm", post(confirm_pairing))
        .route("/v1/pairing/{id}", get(pairing_status))
        .route("/v1/device", get(current_device))
        .route("/v1/join/preview", post(join_preview))
        .route("/v1/join/commit", post(join_commit))
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/library/catalog", get(catalog))
        .route("/v1/library/stats", get(library_stats))
        .route(
            "/v1/exchange",
            post(exchange).layer(DefaultBodyLimit::max(15 * 1024 * 1024)),
        )
        .route("/v1/blobs/{hash}", get(download_blob).put(upload_blob))
        .route("/v1/blobs/{hash}/status", get(blob_status))
        .route("/v1/blobs/commit", post(commit_blob))
        .route("/v1/library/export-manifest", get(export_manifest))
        .route("/v1/library/sources", get(source_health))
        .route("/v1/topology", get(topology))
        .route("/v1/identify", post(identify_tracks))
        .route("/v1/identification/status", get(identification_status))
        .route("/v1/identification/results", get(identification_results))
        .route("/v1/blobs/{hash}/stream", get(stream_blob))
        .route("/v1/artwork/candidates", get(artwork_candidates))
        .route("/v1/artwork/resolve", post(resolve_artwork))
        .route("/v1/metadata-overrides", post(set_manual_metadata))
        .route("/v1/library/tracks/remove", post(remove_track))
        .route("/v1/imports", post(create_import))
        .route("/v1/imports/{id}/files", post(register_import_file))
        .route("/v1/imports/{id}/files/{file_id}", put(upload_import_file))
        .route("/v1/imports/{id}/commit", post(commit_import))
        .route("/v1/loudness/status", get(loudness_status))
        .route("/v1/audio-features/status", get(audio_features_status))
        .route("/v1/playback/activity", post(playback_activity))
        .route("/v1/playlists", get(playlists))
        .route("/v1/radio/{hash}", get(radio))
        .route("/v1/shuffle", post(smart_shuffle))
        .route("/v1/jobs/{id}", get(job_status).delete(cancel_job));

    admin_only
        .merge(shared)
        .layer(middleware::from_fn_with_state(
            state.clone(),
            request_telemetry,
        ))
        .with_state(state)
}

/// Slower than this and a request gets logged at `warn` regardless of its outcome —
/// callers timing out on the client side need this visible without turning on debug
/// logging for every request.
const SLOW_REQUEST_THRESHOLD: std::time::Duration = std::time::Duration::from_secs(2);

async fn request_telemetry(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
    next: Next,
) -> Response {
    let method = request.method().to_string();
    let path = request.uri().path().to_owned();
    let started = std::time::Instant::now();
    let response = next.run(request).await;
    let elapsed = started.elapsed();
    let status = response.status().as_u16();
    let _ = state.store.record_http_request(
        &method,
        &path,
        &peer.to_string(),
        status,
        elapsed.as_micros().min(u128::from(u64::MAX)) as u64,
    );
    // `record_http_request` above persists this into `HubStore` for the dashboard,
    // but that's a query-on-demand history, not something an operator sees while a
    // problem is actually happening — these lines are what `journalctl -u aro-server
    // -f` / `RUST_LOG=aro_server=debug` are for.
    if status >= 500 || elapsed >= SLOW_REQUEST_THRESHOLD {
        tracing::warn!(
            method = %method,
            path = %path,
            peer = %peer,
            status,
            elapsed_ms = elapsed.as_millis(),
            "slow or failed request"
        );
    } else {
        tracing::debug!(
            method = %method,
            path = %path,
            peer = %peer,
            status,
            elapsed_ms = elapsed.as_millis(),
            "request handled"
        );
    }
    response
}

async fn playback_activity(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(snapshot): Json<PlaybackActivitySnapshot>,
) -> Result<StatusCode, ApiError> {
    let device_id = if bearer(&headers).is_some_and(|token| token == state.admin_token) {
        if !is_peer_allowed(&state.admin_allow, peer.ip()) {
            return Err(ApiError::forbidden(
                "admin_network_denied",
                "This network is not permitted to report local playback.",
            ));
        }
        state.hub_id
    } else {
        require_device(&state, &headers)?
    };
    state
        .store
        .record_playback_activity(device_id, &snapshot, Some(&peer.to_string()))?;
    Ok(StatusCode::NO_CONTENT)
}

async fn pairing_requests(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_admin(&state, &headers)?;
    Ok(Json(json!(state.pairing.pending_requests())))
}

async fn folders(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_admin(&state, &headers)?;
    Ok(Json(json!(
        state.sources.list().map_err(ApiError::internal)?
    )))
}

#[derive(Deserialize)]
struct AddFolderRequest {
    path: PathBuf,
}

async fn add_folder(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<AddFolderRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_admin(&state, &headers)?;
    let manager = state.sources.clone();
    let folder = tokio::task::spawn_blocking(move || manager.add(&request.path))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::internal)?;
    Ok(Json(json!(folder)))
}

#[derive(Deserialize)]
struct ScanFoldersRequest {
    source_id: Option<Uuid>,
}

async fn scan_folders(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<ScanFoldersRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_admin(&state, &headers)?;
    let manager = state.sources.clone();
    let changed = tokio::task::spawn_blocking(move || match request.source_id {
        Some(id) => manager.scan(id),
        None => {
            manager.scan_all()?;
            Ok(0)
        }
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::internal)?;
    Ok(Json(json!({"changed_songs": changed})))
}

#[derive(Deserialize)]
struct RemoveFolderRequest {
    source_id: Uuid,
}

async fn remove_folder(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<RemoveFolderRequest>,
) -> Result<StatusCode, ApiError> {
    require_admin(&state, &headers)?;
    if state
        .sources
        .remove(request.source_id)
        .map_err(ApiError::internal)?
    {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found("folder_not_found"))
    }
}

#[derive(Deserialize)]
struct RelocateFolderRequest {
    source_id: Uuid,
    path: PathBuf,
}

async fn relocate_folder(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<RelocateFolderRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_admin(&state, &headers)?;
    let manager = state.sources.clone();
    let folder =
        tokio::task::spawn_blocking(move || manager.relocate(request.source_id, &request.path))
            .await
            .map_err(ApiError::internal)?
            .map_err(ApiError::internal)?;
    Ok(Json(json!(folder)))
}

#[derive(Deserialize)]
struct RemoveTrackRequest {
    content_hash: String,
}

async fn remove_track(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<RemoveTrackRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !bearer(&headers).is_some_and(|token| admin_token_matches(&state, token)) {
        let device_id = require_device(&state, &headers)?;
        require_contributor(&state, device_id)?;
    }
    let removed = state
        .store
        .tombstone_by_hash(&request.content_hash, state.hub_id)?;
    Ok(Json(json!({"removed": removed})))
}

#[derive(Clone, Serialize, Deserialize)]
struct ImportSessionRecord {
    import_id: Uuid,
    source_id: Uuid,
    owner_device_id: Uuid,
    source_name: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct ImportFileRecord {
    file_id: Uuid,
    relative_path: String,
    size: u64,
}

#[derive(Deserialize)]
struct CreateImportRequest {
    source_name: String,
}

#[derive(Serialize)]
struct CreateImportResponse {
    import_id: Uuid,
    source_id: Uuid,
}

#[derive(Deserialize)]
struct RegisterImportFileRequest {
    file_id: Uuid,
    relative_path: String,
    size: u64,
}

#[derive(Serialize)]
struct ImportFileStatus {
    file_id: Uuid,
    uploaded_size: u64,
    size: u64,
}

fn import_root(state: &AppState) -> PathBuf {
    state.store.root().join("ingest")
}

fn import_session_path(state: &AppState, id: Uuid) -> PathBuf {
    import_root(state).join(id.to_string())
}

async fn load_import_session(
    state: &AppState,
    id: Uuid,
    device_id: Uuid,
) -> Result<(PathBuf, ImportSessionRecord), ApiError> {
    let path = import_session_path(state, id);
    let bytes = fs::read(path.join("session.json"))
        .await
        .map_err(|_| ApiError::not_found("import_not_found"))?;
    let session: ImportSessionRecord =
        serde_json::from_slice(&bytes).map_err(ApiError::internal)?;
    if session.owner_device_id != device_id {
        return Err(ApiError::forbidden(
            "import_owner_mismatch",
            "This import belongs to another device.",
        ));
    }
    Ok((path, session))
}

async fn create_import(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<CreateImportRequest>,
) -> Result<Json<CreateImportResponse>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let source_name = request.source_name.trim();
    if source_name.is_empty() || source_name.len() > 255 {
        return Err(ApiError::bad_request("invalid_source_name"));
    }
    let record = ImportSessionRecord {
        import_id: Uuid::new_v4(),
        source_id: Uuid::new_v4(),
        owner_device_id: device_id,
        source_name: source_name.to_owned(),
    };
    let path = import_session_path(&state, record.import_id);
    fs::create_dir_all(path.join("files"))
        .await
        .map_err(ApiError::internal)?;
    fs::write(
        path.join("session.json"),
        serde_json::to_vec(&record).map_err(ApiError::internal)?,
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(CreateImportResponse {
        import_id: record.import_id,
        source_id: record.source_id,
    }))
}

async fn register_import_file(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Json(request): Json<RegisterImportFileRequest>,
) -> Result<Json<ImportFileStatus>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let (path, _) = load_import_session(&state, id, device_id).await?;
    let relative = FilePath::new(&request.relative_path);
    if request.size == 0
        || relative.is_absolute()
        || relative.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(ApiError::bad_request("invalid_import_file"));
    }
    let record = ImportFileRecord {
        file_id: request.file_id,
        relative_path: request.relative_path,
        size: request.size,
    };
    let metadata = path.join("files").join(format!("{}.json", request.file_id));
    if metadata.exists() {
        let existing: ImportFileRecord =
            serde_json::from_slice(&fs::read(&metadata).await.map_err(ApiError::internal)?)
                .map_err(ApiError::internal)?;
        if existing.relative_path != record.relative_path || existing.size != record.size {
            return Err(ApiError::conflict("import_file_mismatch"));
        }
    } else {
        fs::write(
            &metadata,
            serde_json::to_vec(&record).map_err(ApiError::internal)?,
        )
        .await
        .map_err(ApiError::internal)?;
    }
    let uploaded_size = fs::metadata(path.join("files").join(format!("{}.part", request.file_id)))
        .await
        .map(|value| value.len())
        .unwrap_or(0);
    Ok(Json(ImportFileStatus {
        file_id: request.file_id,
        uploaded_size,
        size: request.size,
    }))
}

async fn upload_import_file(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((id, file_id)): Path<(Uuid, Uuid)>,
    bytes: Bytes,
) -> Result<Json<ImportFileStatus>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let (path, _) = load_import_session(&state, id, device_id).await?;
    let record: ImportFileRecord = serde_json::from_slice(
        &fs::read(path.join("files").join(format!("{file_id}.json")))
            .await
            .map_err(|_| ApiError::not_found("import_file_not_found"))?,
    )
    .map_err(ApiError::internal)?;
    let offset = headers
        .get("x-aro-offset")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| ApiError::bad_request("missing_upload_offset"))?;
    let target = path.join("files").join(format!("{file_id}.part"));
    let uploaded = fs::metadata(&target)
        .await
        .map(|value| value.len())
        .unwrap_or(0);
    if uploaded != offset || offset.saturating_add(bytes.len() as u64) > record.size {
        return Err(ApiError::conflict("import_offset_mismatch"));
    }
    let mut output = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&target)
        .await
        .map_err(ApiError::internal)?;
    use tokio::io::AsyncWriteExt;
    output.write_all(&bytes).await.map_err(ApiError::internal)?;
    output.flush().await.map_err(ApiError::internal)?;
    Ok(Json(ImportFileStatus {
        file_id,
        uploaded_size: offset + bytes.len() as u64,
        size: record.size,
    }))
}

async fn commit_import(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
) -> Result<Json<SyncJob>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let (path, session) = load_import_session(&state, id, device_id).await?;
    let mut files = Vec::new();
    let mut entries = fs::read_dir(path.join("files"))
        .await
        .map_err(ApiError::internal)?;
    while let Some(entry) = entries.next_entry().await.map_err(ApiError::internal)? {
        if entry.path().extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let record: ImportFileRecord =
            serde_json::from_slice(&fs::read(entry.path()).await.map_err(ApiError::internal)?)
                .map_err(ApiError::internal)?;
        let part = path.join("files").join(format!("{}.part", record.file_id));
        if fs::metadata(&part)
            .await
            .map(|value| value.len())
            .unwrap_or(0)
            != record.size
        {
            return Err(ApiError::conflict("import_incomplete"));
        }
        files.push((record, part));
    }
    if files.is_empty() {
        return Err(ApiError::bad_request("empty_import"));
    }
    let job = state.jobs.create("library_import", files.len() as u64);
    state.jobs.start(job.job_id);
    let task_state = state.clone();
    let job_id = job.job_id;
    tokio::task::spawn_blocking(move || {
        if let Err(error) = commit_import_files(&task_state, &session, &files, job_id) {
            task_state.jobs.fail(job_id, error.to_string());
            return;
        }
        task_state.jobs.complete(job_id);
        let _ = std::fs::remove_dir_all(path);
    });
    Ok(Json(job))
}

fn commit_import_files(
    state: &AppState,
    session: &ImportSessionRecord,
    files: &[(ImportFileRecord, PathBuf)],
    job_id: Uuid,
) -> anyhow::Result<()> {
    let mut known_hashes = state.store.content_hashes()?;
    let now = chrono::Utc::now().timestamp_millis();
    let mut operations = Vec::new();
    for (record, file) in files {
        let (hash, size) = state.store.import_managed(file)?;
        if !known_hashes.insert(hash.clone()) {
            state.jobs.advance(job_id, 1);
            continue;
        }
        let track_id = Uuid::new_v4();
        let timestamp = HybridTimestamp {
            physical_millis: now,
            logical: operations.len() as u32,
            device_id: state.hub_id,
        };
        let mut payload = audio_metadata::song_payload(file, &hash, size, session.source_id);
        if let Some(object) = payload.as_object_mut() {
            object.insert("source_name".into(), json!(session.source_name));
            let relative = FilePath::new(&record.relative_path);
            let filename = relative
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("Unknown");
            object.insert("original_filename".into(), json!(filename));
            object.insert(
                "original_extension".into(),
                json!(
                    relative
                        .extension()
                        .and_then(|value| value.to_str())
                        .unwrap_or("audio")
                ),
            );
            if object.get("title").and_then(Value::as_str)
                == Some(
                    file.file_stem()
                        .and_then(|value| value.to_str())
                        .unwrap_or("Unknown"),
                )
            {
                object.insert(
                    "title".into(),
                    json!(
                        relative
                            .file_stem()
                            .and_then(|value| value.to_str())
                            .unwrap_or("Unknown")
                    ),
                );
            }
        }
        let field_versions = payload
            .as_object()
            .expect("song payload is an object")
            .keys()
            .map(|field| (field.clone(), timestamp.clone()))
            .collect::<BTreeMap<_, _>>();
        operations.push(Operation {
            operation_id: Uuid::new_v4(),
            device_id: state.hub_id,
            entity_type: "track".into(),
            entity_id: track_id.to_string(),
            kind: "upsert".into(),
            payload,
            field_versions,
        });
        if let Some(managed_path) = state.store.blob_path_for_download(&hash)? {
            state.sources.enqueue_processing(&hash, &managed_path)?;
        }
        state.jobs.advance(job_id, 1);
    }
    state.store.append_operations(&operations)?;
    Ok(())
}

async fn hub_info(State(state): State<Arc<AppState>>) -> Json<HubInfo> {
    let _ = state.store.refresh_host_source_health();
    Json(HubInfo {
        hub_id: state.hub_id,
        display_name: state.display_name.clone(),
        protocol_min: MIN_PROTOCOL_VERSION,
        protocol_max: PROTOCOL_VERSION,
        pairing_available: state.pairing.is_open(),
        identification_available: state.identification_available,
    })
}

async fn negotiate(
    Json(request): Json<NegotiateRequest>,
) -> Result<Json<NegotiateResponse>, ApiError> {
    if request.protocol_min > PROTOCOL_VERSION || request.protocol_max < MIN_PROTOCOL_VERSION {
        return Err(ApiError::new(
            StatusCode::UPGRADE_REQUIRED,
            "incompatible_protocol",
            "No mutually supported protocol version",
        ));
    }
    Ok(Json(NegotiateResponse {
        selected_protocol: request.protocol_max.min(PROTOCOL_VERSION),
    }))
}

async fn open_pairing(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_admin(&state, &headers)?;
    let code = state.pairing.open(Duration::minutes(5));
    Ok(Json(json!({
        "code": code,
        "expires_in_seconds": 300
    })))
}

async fn start_pairing(
    State(state): State<Arc<AppState>>,
    Json(request): Json<PairingStartRequest>,
) -> Result<Json<PairingStartResponse>, ApiError> {
    state
        .pairing
        .start(request)
        .map(Json)
        .map_err(pairing_error)
}

async fn pairing_pake1(
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Json(request): Json<PairingPake1Request>,
) -> Result<Json<PairingPake1Response>, ApiError> {
    state
        .pairing
        .pake1(id, &request.pake1)
        .map(Json)
        .map_err(pairing_error)
}

async fn confirm_pairing(
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Json(request): Json<PairingConfirmRequest>,
) -> Result<Json<PairingConfirmResponse>, ApiError> {
    state
        .pairing
        .confirm(id, &request.pake3)
        .map(Json)
        .map_err(pairing_error)
}

#[derive(Deserialize)]
struct PairingStatusQuery {
    device_id: Uuid,
}

async fn pairing_status(
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Query(query): Query<PairingStatusQuery>,
) -> Result<Json<PairingStatusResponse>, ApiError> {
    state
        .pairing
        .status(id, query.device_id)
        .map(Json)
        .map_err(pairing_error)
}

async fn approve_pairing(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<PairingApprovalRequest>,
) -> Result<Json<Option<DeviceCredential>>, ApiError> {
    require_admin(&state, &headers)?;
    let credential = state
        .pairing
        .approve(request.request_id, request.approve, request.can_contribute)
        .map_err(pairing_error)?;
    if let Some(credential) = &credential {
        let summary = state
            .pairing
            .devices()
            .into_iter()
            .find(|device| device.device_id == credential.device_id)
            .ok_or_else(|| ApiError::internal("approved device missing"))?;
        state.store.save_device(&summary, &credential.credential)?;
    }
    Ok(Json(credential))
}

async fn devices(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<DeviceSummary>>, ApiError> {
    require_admin(&state, &headers)?;
    Ok(Json(state.store.devices()?))
}

async fn current_device(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<DeviceSummary>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    state
        .store
        .devices()?
        .into_iter()
        .find(|device| device.device_id == device_id)
        .map(Json)
        .ok_or_else(|| ApiError::not_found("device_not_found"))
}

async fn revoke(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<RevokeRequest>,
) -> Result<StatusCode, ApiError> {
    require_admin(&state, &headers)?;
    if state.store.revoke_device(request.device_id)? {
        state.pairing.revoke(request.device_id);
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found("device_not_found"))
    }
}

async fn update_device_permissions(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<DevicePermissionRequest>,
) -> Result<StatusCode, ApiError> {
    require_admin(&state, &headers)?;
    if state
        .store
        .set_device_contribution(request.device_id, request.can_contribute)?
    {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found("device_not_found"))
    }
}

async fn join_preview(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<JoinPreviewRequest>,
) -> Result<Json<JoinPreview>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    if request.device_id != device_id {
        return Err(ApiError::unauthorized());
    }
    Ok(Json(state.store.create_join_preview(&request)?))
}

async fn join_commit(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<JoinCommitRequest>,
) -> Result<Json<SyncJob>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    let accepted = state.store.commit_join(device_id, &request)?;
    let job = state.jobs.create("first_join", accepted.len() as u64);
    state.jobs.start(job.job_id);
    Ok(Json(
        state
            .jobs
            .complete(job.job_id)
            .ok_or_else(|| ApiError::internal("join job missing"))?,
    ))
}

#[derive(Deserialize)]
struct SnapshotQuery {
    cursor: Option<String>,
    limit: Option<u32>,
}

#[derive(Deserialize)]
struct CatalogQuery {
    cursor: Option<u64>,
    limit: Option<u32>,
    q: Option<String>,
    sort: Option<String>,
}

async fn catalog(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<CatalogQuery>,
) -> Result<Json<CatalogPage>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let store = state.store.clone();
    let page = tokio::task::spawn_blocking(move || {
        store.catalog_page(
            query.cursor.unwrap_or(0),
            query.limit.unwrap_or(50),
            query.q.as_deref(),
            query.sort.as_deref(),
        )
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::internal)?;
    Ok(Json(page))
}

async fn library_stats(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let store = state.store.clone();
    let stats = tokio::task::spawn_blocking(move || store.dashboard_stats())
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::internal)?;
    Ok(Json(stats))
}

async fn snapshot(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<SnapshotQuery>,
) -> Result<Json<SnapshotPage>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let offset = query
        .cursor
        .as_deref()
        .unwrap_or("0")
        .parse::<u64>()
        .map_err(|_| ApiError::bad_request("invalid_cursor"))?;
    let limit = query.limit.unwrap_or(200).clamp(1, 1_000);
    let tracks = state.store.snapshot_tracks(offset, limit)?;
    let next = (tracks.len() == limit as usize).then(|| (offset + tracks.len() as u64).to_string());
    Ok(Json(SnapshotPage {
        tracks,
        next_cursor: next,
    }))
}

async fn exchange(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<ExchangeRequest>,
) -> Result<Json<ExchangeResponse>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    let contributes = request
        .operations
        .iter()
        .any(|operation| matches!(operation.entity_type.as_str(), "track" | "source"))
        || request
            .device_report
            .as_ref()
            .is_some_and(|report| !report.sources.is_empty());
    if contributes {
        require_contributor(&state, device_id)?;
    }
    state.store.record_device_seen(
        device_id,
        true,
        request
            .device_report
            .as_ref()
            .map(|report| report.offline_track_count),
    )?;
    if let Some(report) = &request.device_report {
        state
            .store
            .update_source_health(device_id, &report.sources)?;
    }
    let accepted = state.store.append_operations(&request.operations)?;
    let changes = state
        .store
        .changes_after(request.after_sequence, request.limit)?;
    let next_cursor = changes
        .last()
        .map(|operation| operation.sequence)
        .unwrap_or(request.after_sequence);
    let has_more = state.store.latest_sequence()? > next_cursor;
    Ok(Json(ExchangeResponse {
        accepted,
        changes,
        next_cursor,
        has_more,
    }))
}

async fn blob_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(hash): Path<String>,
) -> Result<Json<BlobStatus>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let (exists, committed_size, uploaded_size) = state.store.blob_status(&hash)?;
    Ok(Json(BlobStatus {
        hash,
        exists,
        committed_size,
        uploaded_size,
    }))
}

async fn upload_blob(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(hash): Path<String>,
    bytes: Bytes,
) -> Result<Json<BlobStatus>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let offset = headers
        .get("x-aro-offset")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| ApiError::bad_request("missing_upload_offset"))?;
    state.store.write_chunk(&hash, offset, &bytes)?;
    let (exists, committed_size, uploaded_size) = state.store.blob_status(&hash)?;
    Ok(Json(BlobStatus {
        hash,
        exists,
        committed_size,
        uploaded_size,
    }))
}

async fn commit_blob(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<BlobCommitRequest>,
) -> Result<Json<BlobStatus>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;
    let committed_size = state.store.commit_blob(&request.hash, request.size)?;
    if state
        .store
        .needs_loudness_analysis(&request.hash, aro_track_id::loudness::ALGORITHM_VERSION)?
        && let Some(path) = state.store.blob_path_for_download(&request.hash)?
    {
        state.sources.loudness().enqueue(request.hash.clone(), path);
    }
    Ok(Json(BlobStatus {
        hash: request.hash,
        exists: true,
        committed_size,
        uploaded_size: 0,
    }))
}

async fn download_blob(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(hash): Path<String>,
) -> Result<Response, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let path = state
        .store
        .blob_path_for_download(&hash)?
        .ok_or_else(|| ApiError::not_found("blob_not_found"))?;
    download_range_tracked(
        path,
        headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
        state.telemetry.clone(),
    )
    .await
}

#[derive(Deserialize)]
struct StreamQualityQuery {
    #[serde(default)]
    quality: Option<String>,
}

/// Serves a track at a chosen quality, transcoding to Opus when one below `original` is
/// asked for. This is what low data mode actually rides on: a losslessly-ripped library
/// averages ~24 MB a track, and the same music at 96 kbps is a little over 2 MB.
///
/// Two paths, deliberately different:
///
/// - **Already encoded** — served as an ordinary blob, with range requests, so seeking
///   works exactly as it does for an original file.
/// - **Not yet encoded** — encoded and streamed at the same time. Waiting for a complete
///   encode would mean 25–45 seconds of silence before playback starts on the reference
///   hub; emitting frames as they are produced starts audio in about a second, and at
///   6.5–8.7× realtime the encoder stays far ahead of the listener. The finished encode is
///   then cached, so the seek-less first play happens at most once per track and quality.
async fn stream_blob(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(hash): Path<String>,
    Query(query): Query<StreamQualityQuery>,
) -> Result<Response, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let quality = query
        .quality
        .as_deref()
        .map(|value| {
            aro_track_id::transcode::StreamQuality::from_str(value)
                .ok_or_else(|| ApiError::bad_request("unknown_quality"))
        })
        .transpose()?
        .unwrap_or(aro_track_id::transcode::StreamQuality::Original);

    let source = state
        .store
        .blob_path_for_download(&hash)?
        .ok_or_else(|| ApiError::not_found("blob_not_found"))?;
    if quality == aro_track_id::transcode::StreamQuality::Original {
        return download_range_tracked(
            source,
            headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
            state.telemetry.clone(),
        )
        .await;
    }

    if let Some(cached) = state.store.transcoded_blob(&hash, quality.as_str())?
        && let Some(path) = state.store.blob_path_for_download(&cached)?
    {
        return download_range_tracked(
            path,
            headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
            state.telemetry.clone(),
        )
        .await;
    }

    // Waiting here rather than inside the blocking task is deliberate: it applies
    // backpressure at the point a listener asks, instead of piling up encodes that each
    // occupy a pool thread while waiting their turn.
    let permit = state
        .transcode_slots
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| ApiError::internal("transcode capacity unavailable"))?;

    let (sender, receiver) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(8);
    let store = state.store.clone();
    let cache_hash = hash.clone();
    // Encoding is CPU-bound and blocking, so it belongs off the async runtime's threads.
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let mut sink = ChannelSink {
            sender,
            spill: Vec::new(),
        };
        let result = aro_track_id::transcode::transcode_to_ogg_opus(&source, quality, &mut sink);
        match result {
            Ok(()) => {
                // Only a complete encode is worth caching: a half-written stream would be
                // served forever as though it were the whole track.
                if let Err(error) = cache_encoded(&store, &cache_hash, quality, &sink.spill) {
                    tracing::warn!(%error, "failed to cache transcoded audio");
                }
            }
            Err(error) => {
                tracing::warn!(%error, hash = %cache_hash, "transcode failed");
                let _ = sink.sender.blocking_send(Err(std::io::Error::other(error)));
            }
        }
    });

    let stream = tokio_stream::wrappers::ReceiverStream::new(receiver);
    let mut response = Response::new(axum::body::Body::from_stream(stream));
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("audio/ogg"),
    );
    // No length is known while encoding, and a partially-encoded stream cannot satisfy a
    // range request — so seeking is unavailable until the cached copy exists.
    response.headers_mut().insert(
        header::ACCEPT_RANGES,
        header::HeaderValue::from_static("none"),
    );
    Ok(response)
}

fn cache_encoded(
    store: &HubStore,
    content_hash: &str,
    quality: aro_track_id::transcode::StreamQuality,
    bytes: &[u8],
) -> anyhow::Result<()> {
    let temp = tempfile::NamedTempFile::new()?;
    std::fs::write(temp.path(), bytes)?;
    let (blob_hash, size) = store.import_managed(temp.path())?;
    store.record_transcoded_blob(content_hash, quality.as_str(), &blob_hash, size)?;
    Ok(())
}

/// Forwards encoded bytes to the HTTP response as they are produced, while keeping a copy
/// so the finished encode can be cached. The copy is the whole point of doing both at once:
/// the listener gets audio immediately *and* the next play is a cheap, seekable blob read.
struct ChannelSink {
    sender: tokio::sync::mpsc::Sender<Result<Vec<u8>, std::io::Error>>,
    spill: Vec<u8>,
}

impl std::io::Write for ChannelSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.spill.extend_from_slice(buf);
        // A closed receiver means the listener skipped or disconnected. Reporting success
        // lets the encode run to completion so the work still lands in the cache.
        let _ = self.sender.blocking_send(Ok(buf.to_vec()));
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

async fn export_manifest(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<ExportManifest>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    state.store.refresh_host_source_health()?;
    state.store.garbage_collect_expired_blobs()?;
    Ok(Json(state.store.export_manifest(&state.display_name)?))
}

/// Auto-generated playlists from this hub's canonical analytics — see
/// `crate::playlists`. The hub generates; clients (local or remote) only map the
/// returned content hashes onto their own catalogs and render.
#[derive(Deserialize)]
struct PlaylistsQuery {
    /// The caller's local UTC offset in minutes (positive east of UTC) — scopes
    /// Morning Rotation/Late Night to *this* caller's timezone. Defaults to 0 (UTC)
    /// for a caller that doesn't send it.
    #[serde(default)]
    utc_offset_minutes: i32,
}

async fn playlists(
    State(state): State<Arc<AppState>>,
    Query(query): Query<PlaylistsQuery>,
    headers: HeaderMap,
) -> Result<Json<Vec<crate::playlists::GeneratedPlaylist>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let store = state.store.clone();
    let seeds = tokio::task::spawn_blocking(move || store.playlist_seeds())
        .await
        .map_err(|error| ApiError::internal(error.to_string()))??;
    Ok(Json(crate::playlists::generate(
        &seeds,
        chrono::Utc::now(),
        query.utc_offset_minutes,
    )))
}

#[derive(Deserialize)]
struct RadioQuery {
    #[serde(default = "default_radio_limit")]
    limit: usize,
}

fn default_radio_limit() -> usize {
    crate::playlists::RADIO_DEFAULT_LIMIT
}

#[derive(Deserialize)]
struct SmartShuffleRequest {
    content_hashes: Vec<String>,
    /// Track to begin the walk from — normally whatever the listener just picked,
    /// so their choice still plays first. Optional; omitted means "start anywhere".
    #[serde(default)]
    start: Option<String>,
}

/// Reorders a queue so consecutive tracks sound alike (see
/// `crate::playlists::smart_shuffle`). A POST rather than a GET because a queue can
/// run to hundreds of hashes, well past what belongs in a URL.
///
/// Hashes the hub doesn't recognize are simply absent from the response, so the
/// client must treat this as a *reordering hint* and keep any it doesn't get back —
/// see the client's own note on preserving unknown tracks.
async fn smart_shuffle(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<SmartShuffleRequest>,
) -> Result<Json<Vec<String>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let seeds = state.store.playlist_seeds()?;
    Ok(Json(crate::playlists::smart_shuffle(
        &seeds,
        &request.content_hashes,
        request.start.as_deref(),
    )))
}

/// Tier 3 "seed-track radio" (see `crate::playlists::radio`) for a remote client —
/// local-socket equivalent is `HubControlClient.radio(contentHash:)`.
async fn radio(
    State(state): State<Arc<AppState>>,
    Path(hash): Path<String>,
    Query(query): Query<RadioQuery>,
    headers: HeaderMap,
) -> Result<Json<Option<crate::playlists::GeneratedPlaylist>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let store = state.store.clone();
    let seeds = tokio::task::spawn_blocking(move || store.playlist_seeds())
        .await
        .map_err(|error| ApiError::internal(error.to_string()))??;
    Ok(Json(crate::playlists::radio(&seeds, &hash, query.limit)))
}

async fn source_health(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<SourceHealthReport>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    state.store.refresh_host_source_health()?;
    Ok(Json(state.store.source_health()?))
}

async fn topology(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<TopologySnapshot>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    state.store.refresh_host_source_health()?;
    Ok(Json(TopologySnapshot {
        hub_id: state.hub_id,
        display_name: state.display_name.clone(),
        track_count: state.store.active_track_count()?,
        devices: state.store.devices()?,
        sources: state.store.source_health()?,
        active_transfers: state.telemetry.active_transfers(),
        live_playback: state.store.topology_live_activity()?,
    }))
}

#[derive(Deserialize)]
struct ArtworkCandidatesQuery {
    content_hash: String,
    /// Discards the cached list and walks MusicBrainz again — for when art has been
    /// uploaded to the archive since the last look.
    #[serde(default)]
    refresh: bool,
}

/// Every cover a listener could plausibly choose for this track: each pressing of its
/// album, plus one cover from each of the artist's other albums. Identification only ever
/// stores the single front cover of the one release it matched, which is a reasonable
/// default and a poor menu — see `aro_track_id::artwork` for why the archive's per-release
/// population makes that default miss most of what exists.
///
/// Cached per release-group, because a cold walk costs dozens of rate-limited requests.
async fn artwork_candidates(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ArtworkCandidatesQuery>,
) -> Result<Json<Vec<aro_track_id::artwork::ArtworkCandidate>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    let result = state
        .store
        .identification_result(&query.content_hash)?
        .ok_or_else(|| ApiError::not_found("track_not_identified"))?;
    // Keyed by release-group so every track on an album shares one walk; falling back to
    // the release, then the track itself, when identification resolved less than that.
    let cache_key = result
        .release_group_id
        .clone()
        .or_else(|| result.release_id.clone())
        .unwrap_or_else(|| query.content_hash.clone());
    if !query.refresh
        && let Some(cached) = state.store.cached_artwork_candidates(&cache_key)?
        && let Ok(candidates) = serde_json::from_str(&cached)
    {
        return Ok(Json(candidates));
    }
    let candidates = aro_track_id::artwork::discover_candidates(
        &state.musicbrainz,
        &state.artwork_http,
        &state.musicbrainz_user_agent,
        &state.store,
        result.release_id.as_deref(),
        result.release_group_id.as_deref(),
        result.album.as_deref(),
    )
    .await;
    if let Ok(encoded) = serde_json::to_string(&candidates) {
        state.store.cache_artwork_candidates(&cache_key, &encoded)?;
    }
    Ok(Json(candidates))
}

#[derive(Deserialize)]
struct ResolveArtworkRequest {
    image_url: String,
}

#[derive(Serialize)]
struct ResolveArtworkResponse {
    blob: String,
}

/// Pulls the full-resolution original for a candidate the listener has actually chosen and
/// caches it as a blob. Discovery deliberately only fetches thumbnails, so this is where
/// the real bytes are paid for — once, for one image.
async fn resolve_artwork(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<ResolveArtworkRequest>,
) -> Result<Json<ResolveArtworkResponse>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    // Only the archive serves these, and the URL arrives from a client: without this an
    // authenticated device could point the hub at an arbitrary host.
    if !request.image_url.starts_with("https://coverartarchive.org/")
        && !request.image_url.starts_with("https://archive.org/")
        && !request.image_url.starts_with("https://ia")
    {
        return Err(ApiError::bad_request("unsupported_artwork_host"));
    }
    let blob = aro_track_id::artwork::resolve_full_image(
        &state.artwork_http,
        &state.musicbrainz_user_agent,
        &state.store,
        &request.image_url,
    )
    .await
    .ok_or_else(|| ApiError::not_found("artwork_unavailable"))?;
    Ok(Json(ResolveArtworkResponse { blob }))
}

async fn set_manual_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<crate::control::ManualMetadataRequest>,
) -> Result<Json<Value>, ApiError> {
    let device_id = if bearer(&headers).is_some_and(|token| admin_token_matches(&state, token)) {
        state.hub_id
    } else {
        require_device(&state, &headers)?
    };
    Ok(Json(json!({
        "updated": crate::control::apply_manual_metadata(&state, request, device_id)
            .map_err(|error| ApiError::internal(error.to_string()))?
    })))
}

#[derive(Deserialize)]
struct IdentifyTracksRequest {
    content_hashes: Vec<String>,
}

#[derive(serde::Serialize)]
struct IdentifyTracksResponse {
    queued: usize,
    unresolved: Vec<String>,
}

/// Remote-client equivalent of the local control socket's `identify_tracks` command
/// (see `crate::control::ControlCommand::IdentifyTracks`) — reachable over HTTPS so a
/// Mac that's a pure remote client of this hub (no `aro-server` of its own running
/// locally) can still trigger "Sync Track/Album/All Data", not only a self-hosting one.
/// Deliberately does *not* trust a client-supplied file path the way the control-socket
/// command does — that only works there because the local case has client and server
/// on the same filesystem by construction. A remote caller only ever supplies a content
/// hash; this resolves the on-disk path itself via `track_id_for_hash` /
/// `live_path_for_track`, so the caller's own filesystem layout is irrelevant.
async fn identify_tracks(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<IdentifyTracksRequest>,
) -> Result<Json<IdentifyTracksResponse>, ApiError> {
    let device_id = require_device(&state, &headers)?;
    require_contributor(&state, device_id)?;

    let identification = state.sources.identification();
    let mut queued = 0;
    let mut unresolved = Vec::new();
    for hash in request.content_hashes {
        let path = state
            .store
            .track_id_for_hash(&hash)?
            .and_then(|track_id| state.store.live_path_for_track(track_id).ok().flatten());
        match path {
            Some(path) => {
                identification.enqueue(hash, path);
                queued += 1;
            }
            None => unresolved.push(hash),
        }
    }
    Ok(Json(IdentifyTracksResponse { queued, unresolved }))
}

/// Remote-client equivalent of the control socket's `identification_status` command —
/// lets a pure remote client's Metadata page show live queue counts the same way the
/// self-hosting case already does locally.
async fn identification_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<aro_track_id::QueueStatus>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    Ok(Json(state.sources.identification().status().await))
}

#[derive(Deserialize)]
struct IdentificationResultsQuery {
    /// Results recorded strictly after this `identified_at`, oldest first — the
    /// caller passes the `identifiedAt` of the last result it already merged, or 0
    /// to fetch everything.
    #[serde(default)]
    after: i64,
    #[serde(default = "default_identification_results_limit")]
    limit: u32,
}

/// Mirrors the control socket's own default so both transports page identically.
fn default_identification_results_limit() -> u32 {
    200
}

/// Network equivalent of the control socket's `IdentificationResults` command. Both
/// exist because identification results deliberately live *outside* the CRDT operation
/// log (they're keyed by content hash, not `hub_track_id` — see
/// `IdentificationResult`'s doc comment), so they never reach a client through
/// `/v1/exchange` the way track metadata does. Without this route a purely remote
/// client had no way at all to receive them, which stranded Cover Art Archive artwork
/// on the hub: a track with no *embedded* art would render as the "no artwork"
/// placeholder forever, even though the hub had long since fetched and cached a cover
/// for it.
async fn identification_results(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<IdentificationResultsQuery>,
) -> Result<Json<Vec<aro_sync_store::IdentificationResult>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    Ok(Json(
        state
            .store
            .identification_results_since(query.after, query.limit)?,
    ))
}

async fn loudness_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<aro_track_id::loudness::LoudnessQueueStatus>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    Ok(Json(state.sources.loudness().status().await))
}

async fn audio_features_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<aro_track_id::audio_features::AudioFeatureQueueStatus>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    Ok(Json(state.sources.audio_features().status().await))
}

#[cfg(test)]
async fn download_range(path: PathBuf, range: Option<&str>) -> Result<Response, ApiError> {
    download_range_inner(path, range, None).await
}

pub(crate) async fn download_range_tracked(
    path: PathBuf,
    range: Option<&str>,
    telemetry: RuntimeTelemetry,
) -> Result<Response, ApiError> {
    download_range_inner(path, range, Some(telemetry)).await
}

async fn download_range_inner(
    path: PathBuf,
    range: Option<&str>,
    telemetry: Option<RuntimeTelemetry>,
) -> Result<Response, ApiError> {
    let mut file = fs::File::open(path).await.map_err(ApiError::internal)?;
    let total = file.metadata().await.map_err(ApiError::internal)?.len();
    let requested = match range {
        Some(value) => match parse_byte_range(value, total) {
            Ok(value) => Some(value),
            Err(()) => return Ok(range_not_satisfiable(total)),
        },
        None => None,
    };
    let (status, start, end) = match requested {
        Some((start, end)) => (StatusCode::PARTIAL_CONTENT, start, end),
        None => (StatusCode::OK, 0, total.saturating_sub(1)),
    };
    let length = if total == 0 { 0 } else { end - start + 1 };
    if start > 0 {
        file.seek(std::io::SeekFrom::Start(start))
            .await
            .map_err(ApiError::internal)?;
    }
    let stream = ReaderStream::new(file.take(length));
    let mut response = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, length.to_string());
    if status == StatusCode::PARTIAL_CONTENT {
        response = response.header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{total}"),
        );
    }
    match telemetry {
        Some(telemetry) => response
            .body(Body::from_stream(telemetry.track(stream)))
            .map_err(ApiError::internal),
        None => response
            .body(Body::from_stream(stream))
            .map_err(ApiError::internal),
    }
}

fn parse_byte_range(value: &str, total: u64) -> Result<(u64, u64), ()> {
    let spec = value.strip_prefix("bytes=").ok_or(())?;
    if spec.contains(',') || total == 0 {
        return Err(());
    }
    let (start, end) = spec.split_once('-').ok_or(())?;
    if start.is_empty() {
        return Err(());
    }
    let start = start.parse::<u64>().map_err(|_| ())?;
    let end = if end.is_empty() {
        total - 1
    } else {
        end.parse::<u64>().map_err(|_| ())?
    };
    if start > end || end >= total {
        return Err(());
    }
    Ok((start, end))
}

fn range_not_satisfiable(total: u64) -> Response {
    Response::builder()
        .status(StatusCode::RANGE_NOT_SATISFIABLE)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_RANGE, format!("bytes */{total}"))
        .body(Body::empty())
        .expect("static range response is valid")
}

#[cfg(test)]
mod download_tests {
    use super::*;
    use axum::body::to_bytes;
    use tempfile::NamedTempFile;

    #[test]
    fn parses_bounded_and_open_ended_ranges() {
        assert_eq!(parse_byte_range("bytes=2-4", 8), Ok((2, 4)));
        assert_eq!(parse_byte_range("bytes=5-", 8), Ok((5, 7)));
    }

    #[test]
    fn rejects_invalid_or_multiple_ranges() {
        assert_eq!(parse_byte_range("items=0-1", 8), Err(()));
        assert_eq!(parse_byte_range("bytes=-2", 8), Err(()));
        assert_eq!(parse_byte_range("bytes=4-3", 8), Err(()));
        assert_eq!(parse_byte_range("bytes=0-8", 8), Err(()));
        assert_eq!(parse_byte_range("bytes=0-1,4-5", 8), Err(()));
    }

    #[tokio::test]
    async fn streams_only_the_requested_bytes() {
        let file = NamedTempFile::new().unwrap();
        std::fs::write(file.path(), b"abcdefgh").unwrap();

        let response = download_range(file.path().to_path_buf(), Some("bytes=2-4"))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(response.headers()[header::ACCEPT_RANGES], "bytes");
        assert_eq!(response.headers()[header::CONTENT_LENGTH], "3");
        assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes 2-4/8");
        let body = to_bytes(response.into_body(), 16).await.unwrap();
        assert_eq!(&body[..], b"cde");
    }

    #[tokio::test]
    async fn invalid_range_reports_the_complete_length() {
        let file = NamedTempFile::new().unwrap();
        std::fs::write(file.path(), b"abcdefgh").unwrap();

        let response = download_range(file.path().to_path_buf(), Some("bytes=8-"))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes */8");
    }
}

async fn job_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
) -> Result<Json<SyncJob>, ApiError> {
    require_device(&state, &headers)?;
    state
        .jobs
        .get(id)
        .map(Json)
        .ok_or_else(|| ApiError::not_found("job_not_found"))
}

async fn cancel_job(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
) -> Result<Json<SyncJob>, ApiError> {
    require_device(&state, &headers)?;
    state
        .jobs
        .cancel(id)
        .map(Json)
        .ok_or_else(|| ApiError::not_found("job_not_found"))
}

/// Compares two tokens in constant time (both are SHA-256-hashed to
/// fixed-size arrays first, since `ConstantTimeEq` requires equal-length
/// inputs and tokens may vary in length) to avoid leaking a match via
/// response-time timing.
fn tokens_match(a: &str, b: &str) -> bool {
    let a_hash: [u8; 32] = Sha256::digest(a.as_bytes()).into();
    let b_hash: [u8; 32] = Sha256::digest(b.as_bytes()).into();
    a_hash.ct_eq(&b_hash).into()
}

fn admin_token_matches(state: &AppState, supplied: &str) -> bool {
    tokens_match(supplied, &state.admin_token)
}

fn require_admin(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    let supplied = bearer(headers).unwrap_or_default();
    if admin_token_matches(state, supplied) {
        Ok(())
    } else {
        Err(ApiError::unauthorized())
    }
}

fn require_device(state: &AppState, headers: &HeaderMap) -> Result<Uuid, ApiError> {
    let device_id = headers
        .get("x-aro-device")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
        .ok_or_else(ApiError::unauthorized)?;
    if state
        .store
        .authorize_device(device_id, bearer(headers).unwrap_or_default())?
    {
        state.store.record_device_seen(device_id, false, None)?;
        Ok(device_id)
    } else {
        Err(ApiError::unauthorized())
    }
}

fn require_contributor(state: &AppState, device_id: Uuid) -> Result<(), ApiError> {
    if !state.store.device_can_contribute(device_id)? {
        Err(ApiError::forbidden(
            "contribution_not_allowed",
            "This device is not allowed to add music.",
        ))
    } else if !state.store.library_accepts_contributions()? {
        Err(ApiError::forbidden(
            "linked_library_is_read_only",
            "This is a linked library. It reads files in place and cannot accept uploads.",
        ))
    } else {
        Ok(())
    }
}

fn require_device_or_admin(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    if bearer(headers).is_some_and(|token| admin_token_matches(state, token)) {
        return Ok(());
    }
    require_device(state, headers).map(|_| ())
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

fn pairing_error(error: PairingError) -> ApiError {
    match error {
        PairingError::Unavailable => {
            ApiError::new(StatusCode::FORBIDDEN, "pairing_closed", &error.to_string())
        }
        PairingError::RequestNotFound => ApiError::not_found("pairing_request_not_found"),
        PairingError::TooManyAttempts => ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "too_many_pairing_attempts",
            &error.to_string(),
        ),
        _ => ApiError::bad_request(&error.to_string()),
    }
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: String,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, code: &str, message: &str) -> Self {
        Self {
            status,
            code: code.into(),
            message: message.into(),
        }
    }

    fn bad_request(code: &str) -> Self {
        Self::new(StatusCode::BAD_REQUEST, code, code)
    }

    fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "A valid device credential is required",
        )
    }

    fn forbidden(code: &str, message: &str) -> Self {
        Self::new(StatusCode::FORBIDDEN, code, message)
    }

    fn not_found(code: &str) -> Self {
        Self::new(StatusCode::NOT_FOUND, code, code)
    }

    fn conflict(code: &str) -> Self {
        Self::new(StatusCode::CONFLICT, code, code)
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        tracing::error!(%error, "request failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "The request could not be completed",
        )
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(ErrorResponse {
                code: self.code,
                message: self.message,
            }),
        )
            .into_response()
    }
}

impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::OffsetMismatch { .. } | StoreError::SizeMismatch => {
                Self::new(StatusCode::CONFLICT, "upload_conflict", &error.to_string())
            }
            StoreError::JoinPreviewNotFound => Self::new(
                StatusCode::CONFLICT,
                "join_preview_invalid",
                &error.to_string(),
            ),
            aro_sync_store::StoreError::Blob(_) => Self::bad_request(&error.to_string()),
            _ => Self::internal(error),
        }
    }
}

#[cfg(test)]
mod admin_access_tests {
    use super::*;

    #[test]
    fn tokens_match_requires_equal_tokens() {
        assert!(tokens_match("secret-token", "secret-token"));
        assert!(!tokens_match("secret-token", "different-token"));
        assert!(!tokens_match("secret-token", ""));
        assert!(!tokens_match("short", "a-much-longer-token-value"));
    }

    #[test]
    fn is_peer_allowed_matches_configured_networks_only() {
        let loopback_only = [
            "127.0.0.0/8".parse::<IpNet>().unwrap(),
            "::1/128".parse::<IpNet>().unwrap(),
        ];
        assert!(is_peer_allowed(
            &loopback_only,
            "127.0.0.1".parse::<IpAddr>().unwrap()
        ));
        assert!(is_peer_allowed(
            &loopback_only,
            "::ffff:127.0.0.1".parse::<IpAddr>().unwrap()
        ));
        assert!(!is_peer_allowed(
            &loopback_only,
            "192.168.1.50".parse::<IpAddr>().unwrap()
        ));

        let lan_subnet = ["192.168.1.0/24".parse::<IpNet>().unwrap()];
        assert!(is_peer_allowed(
            &lan_subnet,
            "192.168.1.50".parse::<IpAddr>().unwrap()
        ));
        assert!(!is_peer_allowed(
            &lan_subnet,
            "10.0.0.1".parse::<IpAddr>().unwrap()
        ));

        let anyone = ["0.0.0.0/0".parse::<IpNet>().unwrap()];
        assert!(is_peer_allowed(
            &anyone,
            "203.0.113.5".parse::<IpAddr>().unwrap()
        ));

        let none: [IpNet; 0] = [];
        assert!(!is_peer_allowed(
            &none,
            "127.0.0.1".parse::<IpAddr>().unwrap()
        ));
    }
}
