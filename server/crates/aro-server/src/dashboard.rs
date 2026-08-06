use crate::http::AppState;
use axum::{
    Json, Router,
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::{get, post, put},
};
use chrono::Duration;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Instant};
use subtle::ConstantTimeEq;
use uuid::Uuid;

#[derive(Clone)]
pub struct DashboardState {
    app: Arc<AppState>,
    started: Instant,
    storage_mode: &'static str,
}

impl DashboardState {
    pub fn new(app: AppState, storage_mode: &'static str) -> Self {
        Self {
            app: Arc::new(app),
            started: Instant::now(),
            storage_mode,
        }
    }
}

pub fn router(state: DashboardState) -> Router {
    let admin = Router::new()
        .route("/api/v1/admin/session", get(admin_session))
        .route("/api/v1/admin/config", get(admin_config))
        .route("/api/v1/admin/config/{*key}", put(admin_set_config))
        .route("/api/v1/admin/devices", get(admin_devices))
        .route(
            "/api/v1/admin/devices/permission",
            put(admin_device_permission),
        )
        .route("/api/v1/admin/devices/revoke", post(admin_revoke_device))
        .route(
            "/api/v1/admin/folders",
            get(admin_folders).post(admin_add_folder),
        )
        .route("/api/v1/admin/folders/scan", post(admin_scan_folder))
        .route("/api/v1/admin/folders/remove", post(admin_remove_folder))
        .route(
            "/api/v1/admin/pairing",
            get(admin_pairing).post(admin_open_pairing),
        )
        .route("/api/v1/admin/pairing/approve", post(admin_approve_pairing))
        .route("/api/v1/admin/verify", post(admin_verify))
        .route(
            "/api/v1/admin/metadata-write-back",
            get(admin_write_back).put(admin_set_write_back),
        )
        .route_layer(middleware::from_fn_with_state(state.clone(), admin_guard));

    Router::new()
        .route("/", get(index))
        .route("/api/v1/stats", get(stats))
        .route("/api/v1/overview", get(stats))
        .route("/api/v1/history", get(history))
        .route("/api/v1/library", get(library))
        .route("/api/v1/metadata", get(metadata))
        .route("/api/v1/live", get(live))
        .route("/api/v1/queue", get(queue))
        .route("/api/v1/devices", get(devices))
        .route("/api/v1/sources", get(sources))
        .route("/api/v1/host", get(host))
        .route("/api/v1/traffic", get(traffic))
        .route("/metrics", get(metrics))
        .merge(admin)
        .fallback(not_found)
        .with_state(state)
        .layer(axum::middleware::from_fn(security_headers))
}

async fn admin_guard(
    State(state): State<DashboardState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
    next: Next,
) -> Response {
    if !state
        .app
        .admin_allow
        .iter()
        .any(|network| network.contains(&peer.ip()))
    {
        return admin_error(
            StatusCode::FORBIDDEN,
            "admin_network_denied",
            "This network is not permitted to administer Aro.",
        );
    }
    let authorized = bearer(request.headers()).is_some_and(|token| {
        token
            .as_bytes()
            .ct_eq(state.app.admin_token.as_bytes())
            .into()
    });
    if !authorized {
        return admin_error(
            StatusCode::UNAUTHORIZED,
            "admin_auth_required",
            "Enter the admin token from aro.toml to continue.",
        );
    }
    next.run(request).await
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

fn admin_error(status: StatusCode, code: &str, message: impl std::fmt::Display) -> Response {
    (
        status,
        Json(json!({"error": code, "message": message.to_string()})),
    )
        .into_response()
}

fn admin_internal(error: impl std::fmt::Display) -> Response {
    admin_error(
        StatusCode::INTERNAL_SERVER_ERROR,
        "admin_operation_failed",
        error,
    )
}

async fn admin_session(State(state): State<DashboardState>) -> Json<Value> {
    Json(json!({
        "authenticated": true,
        "display_name": state.app.display_name,
        "pairing_available": state.app.pairing.is_open(),
    }))
}

async fn admin_config(State(state): State<DashboardState>) -> Response {
    match crate::config::Config::load(&state.app.config_path) {
        Ok(config) => Json(json!({
            "display_name": config.display_name,
            "bind": config.bind,
            "advertise_mdns": config.advertise_mdns,
            "storage_mode": config.storage_mode,
            "source_rescan_seconds": config.source_rescan_seconds,
            "admin_allow": config.admin_allow,
            "dashboard": config.dashboard,
            "dlna": config.dlna,
            "acoustid_api_key_configured": !config.acoustid_api_key.is_empty(),
            "musicbrainz_user_agent": config.musicbrainz_user_agent,
            "config_path": state.app.config_path,
            "restart_required": false,
        }))
        .into_response(),
        Err(error) => admin_internal(error),
    }
}

#[derive(Deserialize)]
struct ConfigValue {
    value: String,
}

async fn admin_set_config(
    State(state): State<DashboardState>,
    axum::extract::Path(key): axum::extract::Path<String>,
    Json(request): Json<ConfigValue>,
) -> Response {
    let result = (|| -> anyhow::Result<()> {
        let mut config = crate::config::Config::load(&state.app.config_path)?;
        config.set_field(&key, &request.value)?;
        config.save(&state.app.config_path)?;
        Ok(())
    })();
    match result {
        Ok(()) => Json(json!({"updated": key, "restart_required": true})).into_response(),
        Err(error) => admin_error(StatusCode::BAD_REQUEST, "invalid_config", error),
    }
}

async fn admin_devices(State(state): State<DashboardState>) -> Response {
    match state.app.store.devices() {
        Ok(devices) => Json(json!({"devices": devices})).into_response(),
        Err(error) => admin_internal(error),
    }
}

#[derive(Deserialize)]
struct DevicePermission {
    device_id: Uuid,
    can_contribute: bool,
}

async fn admin_device_permission(
    State(state): State<DashboardState>,
    Json(request): Json<DevicePermission>,
) -> Response {
    match state
        .app
        .store
        .set_device_contribution(request.device_id, request.can_contribute)
    {
        Ok(true) => Json(json!({"updated": true})).into_response(),
        Ok(false) => admin_error(
            StatusCode::NOT_FOUND,
            "device_not_found",
            "Device not found.",
        ),
        Err(error) => admin_internal(error),
    }
}

/// Whether Aro may write its metadata into the library's own audio files.
///
/// Kept out of the `aro.toml` config form deliberately: everything there needs a restart
/// to take effect, while this is read from the store on each request and applies at once.
/// Presenting it alongside settings that don't take hold yet would be misleading about the
/// one control here that changes files on disk.
async fn admin_write_back(State(state): State<DashboardState>) -> Response {
    match aro_track_id::tags::should_persist_to_files(&state.app.store) {
        Ok(enabled) => Json(json!({"enabled": enabled})).into_response(),
        Err(error) => admin_internal(error),
    }
}

#[derive(Deserialize)]
struct WriteBackToggle {
    enabled: bool,
}

async fn admin_set_write_back(
    State(state): State<DashboardState>,
    Json(request): Json<WriteBackToggle>,
) -> Response {
    match state.app.store.set_setting(
        aro_track_id::tags::PERSIST_METADATA_SETTING,
        &json!(request.enabled),
    ) {
        Ok(()) => Json(json!({"enabled": request.enabled})).into_response(),
        Err(error) => admin_internal(error),
    }
}

#[derive(Deserialize)]
struct DeviceTarget {
    device_id: Uuid,
}

async fn admin_revoke_device(
    State(state): State<DashboardState>,
    Json(request): Json<DeviceTarget>,
) -> Response {
    match state.app.store.revoke_device(request.device_id) {
        Ok(true) => {
            state.app.pairing.revoke(request.device_id);
            Json(json!({"revoked": true})).into_response()
        }
        Ok(false) => admin_error(
            StatusCode::NOT_FOUND,
            "device_not_found",
            "Device not found.",
        ),
        Err(error) => admin_internal(error),
    }
}

async fn admin_folders(State(state): State<DashboardState>) -> Response {
    match state.app.sources.list() {
        Ok(folders) => Json(json!({"folders": folders})).into_response(),
        Err(error) => admin_internal(error),
    }
}

#[derive(Deserialize)]
struct FolderPath {
    path: PathBuf,
}

async fn admin_add_folder(
    State(state): State<DashboardState>,
    Json(request): Json<FolderPath>,
) -> Response {
    let sources = state.app.sources.clone();
    match tokio::task::spawn_blocking(move || sources.add(&request.path)).await {
        Ok(Ok(folder)) => (StatusCode::CREATED, Json(json!({"folder": folder}))).into_response(),
        Ok(Err(error)) => admin_error(StatusCode::BAD_REQUEST, "folder_add_failed", error),
        Err(error) => admin_internal(error),
    }
}

#[derive(Deserialize)]
struct FolderTarget {
    source_id: Option<Uuid>,
}

async fn admin_scan_folder(
    State(state): State<DashboardState>,
    Json(request): Json<FolderTarget>,
) -> Response {
    let sources = state.app.sources.clone();
    let result = tokio::task::spawn_blocking(move || match request.source_id {
        Some(source_id) => sources.scan(source_id).map(Some),
        None => sources.scan_all().map(|()| None),
    })
    .await;
    match result {
        Ok(Ok(changed)) => Json(json!({"scanned": true, "changed_songs": changed})).into_response(),
        Ok(Err(error)) => admin_error(StatusCode::BAD_REQUEST, "folder_scan_failed", error),
        Err(error) => admin_internal(error),
    }
}

async fn admin_remove_folder(
    State(state): State<DashboardState>,
    Json(request): Json<FolderTarget>,
) -> Response {
    let Some(source_id) = request.source_id else {
        return admin_error(
            StatusCode::BAD_REQUEST,
            "source_id_required",
            "Choose a folder.",
        );
    };
    match state.app.sources.remove(source_id) {
        Ok(true) => Json(json!({"removed": true})).into_response(),
        Ok(false) => admin_error(
            StatusCode::NOT_FOUND,
            "folder_not_found",
            "Folder not found.",
        ),
        Err(error) => admin_internal(error),
    }
}

async fn admin_pairing(State(state): State<DashboardState>) -> Json<Value> {
    Json(json!({
        "open": state.app.pairing.is_open(),
        "requests": state.app.pairing.pending_requests(),
    }))
}

async fn admin_open_pairing(State(state): State<DashboardState>) -> Json<Value> {
    Json(json!({
        "code": state.app.pairing.open(Duration::minutes(5)),
        "expires_in_seconds": 300,
    }))
}

#[derive(Deserialize)]
struct PairingDecision {
    request_id: Uuid,
    approve: bool,
    #[serde(default)]
    can_contribute: bool,
}

async fn admin_approve_pairing(
    State(state): State<DashboardState>,
    Json(request): Json<PairingDecision>,
) -> Response {
    match state
        .app
        .pairing
        .approve(request.request_id, request.approve, request.can_contribute)
    {
        Ok(credential) => {
            if let Some(credential) = &credential {
                let Some(summary) = state
                    .app
                    .pairing
                    .devices()
                    .into_iter()
                    .find(|device| device.device_id == credential.device_id)
                else {
                    return admin_internal("approved device was not available");
                };
                if let Err(error) = state
                    .app
                    .store
                    .save_device(&summary, &credential.credential)
                {
                    return admin_internal(error);
                }
            }
            Json(json!({"approved": request.approve})).into_response()
        }
        Err(error) => admin_error(StatusCode::BAD_REQUEST, "pairing_failed", error),
    }
}

async fn admin_verify(State(state): State<DashboardState>) -> Response {
    let store = state.app.store.clone();
    match tokio::task::spawn_blocking(move || store.verify_all()).await {
        Ok(Ok((verified, failures))) => {
            Json(json!({"verified": verified, "failures": failures})).into_response()
        }
        Ok(Err(error)) => admin_internal(error),
        Err(error) => admin_internal(error),
    }
}

async fn security_headers(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'",
        ),
    );
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert("x-frame-options", HeaderValue::from_static("DENY"));
    response
}

async fn stats(State(state): State<DashboardState>) -> Response {
    match state.app.store.dashboard_stats() {
        Ok(mut value) => {
            value["transport"] = json!({
                "active_transfers": state.app.telemetry.active_transfers(),
                "completed_transfers": state.app.telemetry.completed_transfers(),
                "bytes_served": state.app.telemetry.bytes_served(),
            });
            Json(value).into_response()
        }
        Err(error) => dashboard_error(error),
    }
}

async fn live(State(state): State<DashboardState>) -> Response {
    match state.app.store.dashboard_live_activity() {
        Ok(value) => Json(json!({
            "generated_at": chrono::Utc::now(),
            "sessions": value,
        }))
        .into_response(),
        Err(error) => dashboard_error(error),
    }
}

async fn queue(State(state): State<DashboardState>) -> Response {
    let status = state.app.sources.identification().status().await;
    Json(json!({
        "generated_at": chrono::Utc::now(),
        "queue": status,
    }))
    .into_response()
}

async fn history(State(state): State<DashboardState>) -> Response {
    stats_section(&state, "listening")
}

async fn library(State(state): State<DashboardState>) -> Response {
    stats_section(&state, "library")
}

async fn metadata(State(state): State<DashboardState>) -> Response {
    stats_section(&state, "metadata")
}

fn stats_section(state: &DashboardState, section: &str) -> Response {
    match state.app.store.dashboard_stats() {
        Ok(value) => {
            let mut response = json!({"generated_at": value["generated_at"]});
            response[section] = value[section].clone();
            Json(response).into_response()
        }
        Err(error) => dashboard_error(error),
    }
}

async fn devices(State(state): State<DashboardState>) -> Response {
    match state.app.store.devices() {
        Ok(value) => Json(json!({
            "generated_at": chrono::Utc::now(),
            "devices": value,
        }))
        .into_response(),
        Err(error) => dashboard_error(error),
    }
}

async fn sources(State(state): State<DashboardState>) -> Response {
    let _ = state.app.store.refresh_host_source_health();
    match state.app.store.source_health() {
        Ok(value) => Json(json!({
            "generated_at": chrono::Utc::now(),
            "sources": value,
        }))
        .into_response(),
        Err(error) => dashboard_error(error),
    }
}

async fn traffic(State(state): State<DashboardState>) -> Response {
    match state.app.store.dashboard_traffic() {
        Ok(mut value) => {
            value["active_transfers"] = json!(state.app.telemetry.active_transfers());
            value["completed_transfers"] = json!(state.app.telemetry.completed_transfers());
            value["bytes_served"] = json!(state.app.telemetry.bytes_served());
            Json(value).into_response()
        }
        Err(error) => dashboard_error(error),
    }
}

async fn host(State(state): State<DashboardState>) -> Json<Value> {
    let data_path = state.app.store.root();
    Json(json!({
        "generated_at": chrono::Utc::now(),
        "hub_id": state.app.hub_id,
        "display_name": state.app.display_name,
        "server_version": env!("CARGO_PKG_VERSION"),
        "protocol_version": aro_sync_protocol::PROTOCOL_VERSION,
        "process_uptime_seconds": state.started.elapsed().as_secs(),
        "operating_system": std::env::consts::OS,
        "architecture": std::env::consts::ARCH,
        "hostname": std::env::var("HOSTNAME").ok(),
        "storage_mode": state.storage_mode,
        "data_path": data_path,
        "disk_free_bytes": fs2::available_space(data_path).ok(),
        "disk_total_bytes": fs2::total_space(data_path).ok(),
    }))
}

async fn metrics(State(state): State<DashboardState>) -> Response {
    let stats = match state.app.store.dashboard_stats() {
        Ok(value) => value,
        Err(error) => return dashboard_error(error),
    };
    let metric = |path: &[&str]| {
        let mut value = &stats;
        for key in path {
            value = &value[*key];
        }
        value.as_f64().unwrap_or_default()
    };
    let body = format!(
        concat!(
            "# HELP aro_server_uptime_seconds Time since the Aro server started.\n",
            "# TYPE aro_server_uptime_seconds gauge\n",
            "aro_server_uptime_seconds {}\n",
            "# HELP aro_active_playback_sessions Playback sessions with a recent heartbeat.\n",
            "# TYPE aro_active_playback_sessions gauge\n",
            "aro_active_playback_sessions {}\n",
            "# HELP aro_connected_devices Authorized devices seen in the last minute.\n",
            "# TYPE aro_connected_devices gauge\n",
            "aro_connected_devices {}\n",
            "# HELP aro_active_media_transfers Open media response streams.\n",
            "# TYPE aro_active_media_transfers gauge\n",
            "aro_active_media_transfers {}\n",
            "# HELP aro_media_bytes_served_total Media bytes served since process start.\n",
            "# TYPE aro_media_bytes_served_total counter\n",
            "aro_media_bytes_served_total {}\n",
            "# HELP aro_library_tracks Tracks in the authoritative library.\n",
            "# TYPE aro_library_tracks gauge\n",
            "aro_library_tracks {}\n",
            "# HELP aro_library_bytes Bytes in the authoritative library.\n",
            "# TYPE aro_library_bytes gauge\n",
            "aro_library_bytes {}\n",
            "# HELP aro_sources_unavailable Unavailable library sources.\n",
            "# TYPE aro_sources_unavailable gauge\n",
            "aro_sources_unavailable {}\n",
            "# HELP aro_metadata_coverage_ratio Fraction of tracks with metadata.\n",
            "# TYPE aro_metadata_coverage_ratio gauge\n",
            "aro_metadata_coverage_ratio{{field=\"title\"}} {}\n",
            "aro_metadata_coverage_ratio{{field=\"artist\"}} {}\n",
            "aro_metadata_coverage_ratio{{field=\"album\"}} {}\n"
        ),
        state.started.elapsed().as_secs(),
        metric(&["live", "active_listeners"]),
        metric(&["live", "connected_devices"]),
        state.app.telemetry.active_transfers(),
        state.app.telemetry.bytes_served(),
        metric(&["library", "track_count"]),
        metric(&["library", "file_size_bytes"]),
        metric(&["sources", "unavailable"]),
        metric(&["metadata", "title_coverage"]),
        metric(&["metadata", "artist_coverage"]),
        metric(&["metadata", "album_coverage"]),
    );
    (
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        body,
    )
        .into_response()
}

async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}

fn dashboard_error(error: impl std::fmt::Display) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"error": "dashboard_query_failed", "message": error.to_string()})),
    )
        .into_response()
}

async fn index() -> Html<&'static str> {
    Html(INDEX)
}

const INDEX: &str = include_str!("dashboard.html");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dashboard_is_self_contained() {
        assert!(INDEX.contains("/api/v1/stats"));
        assert!(!INDEX.contains("https://"));
    }

    #[test]
    fn dashboard_formats_storage_with_conventional_units() {
        assert!(INDEX.contains(r#"const units=["KB","MB","GB","TB","PB"]"#));
        assert!(!INDEX.contains(r#"notation:"compact""#));
        assert!(!INDEX.contains(r#"unitDisplay:"narrow""#));
    }

    #[test]
    fn dashboard_surfaces_identification_queue_detail() {
        assert!(INDEX.contains("/api/v1/queue"));
        assert!(INDEX.contains("q-queued"));
        assert!(INDEX.contains("q-groups"));
        assert!(INDEX.contains("q-processed"));
        assert!(INDEX.contains("q-failed"));
    }

    #[test]
    fn dashboard_surfaces_server_administration() {
        for path in [
            "/api/v1/admin/config",
            "/api/v1/admin/devices",
            "/api/v1/admin/folders",
            "/api/v1/admin/pairing",
            "/api/v1/admin/verify",
        ] {
            assert!(INDEX.contains(path), "dashboard does not use {path}");
        }
        assert!(INDEX.contains("sessionStorage"));
        assert!(!INDEX.contains("localStorage"));
    }

    #[test]
    fn bearer_requires_the_authorization_scheme() {
        let mut headers = HeaderMap::new();
        headers.insert(header::AUTHORIZATION, HeaderValue::from_static("token"));
        assert_eq!(bearer(&headers), None);
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer secret"),
        );
        assert_eq!(bearer(&headers), Some("secret"));
    }
}
