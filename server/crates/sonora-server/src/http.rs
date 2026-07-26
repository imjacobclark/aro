use axum::{
    Json, Router,
    body::Bytes,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use chrono::Duration;
use serde::Deserialize;
use serde_json::json;
use sonora_sync_core::{JobRegistry, PairingError, PairingManager};
use sonora_sync_protocol::*;
use sonora_sync_store::{HubStore, StoreError};
use std::{path::PathBuf, sync::Arc};
use tokio::fs;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub hub_id: Uuid,
    pub display_name: String,
    #[cfg(unix)]
    pub data_dir: PathBuf,
    pub admin_token: String,
    pub pairing: PairingManager,
    pub jobs: JobRegistry,
    pub store: HubStore,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/hub", get(hub_info))
        .route("/v1/negotiate", post(negotiate))
        .route("/v1/pairing/open", post(open_pairing))
        .route("/v1/pairing/start", post(start_pairing))
        .route("/v1/pairing/{id}/pake1", post(pairing_pake1))
        .route("/v1/pairing/{id}/confirm", post(confirm_pairing))
        .route("/v1/pairing/{id}", get(pairing_status))
        .route("/v1/pairing/approve", post(approve_pairing))
        .route("/v1/devices", get(devices))
        .route("/v1/device", get(current_device))
        .route("/v1/devices/revoke", post(revoke))
        .route("/v1/devices/permissions", post(update_device_permissions))
        .route("/v1/join/preview", post(join_preview))
        .route("/v1/join/commit", post(join_commit))
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/exchange", post(exchange))
        .route("/v1/blobs/{hash}", get(download_blob).put(upload_blob))
        .route("/v1/blobs/{hash}/status", get(blob_status))
        .route("/v1/blobs/commit", post(commit_blob))
        .route("/v1/library/export-manifest", get(export_manifest))
        .route("/v1/library/sources", get(source_health))
        .route("/v1/jobs/{id}", get(job_status).delete(cancel_job))
        .with_state(Arc::new(state))
}

async fn hub_info(State(state): State<Arc<AppState>>) -> Json<HubInfo> {
    let _ = state.store.refresh_host_source_health();
    Json(HubInfo {
        hub_id: state.hub_id,
        display_name: state.display_name.clone(),
        protocol_min: MIN_PROTOCOL_VERSION,
        protocol_max: PROTOCOL_VERSION,
        pairing_available: state.pairing.is_open(),
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
        .get("x-sonora-offset")
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
    download_range(
        path,
        headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
    )
    .await
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

async fn source_health(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<SourceHealthReport>>, ApiError> {
    require_device_or_admin(&state, &headers)?;
    state.store.refresh_host_source_health()?;
    Ok(Json(state.store.source_health()?))
}

async fn download_range(path: PathBuf, range: Option<&str>) -> Result<Response, ApiError> {
    let bytes = fs::read(path).await.map_err(ApiError::internal)?;
    let total = bytes.len();
    if let Some(spec) = range.and_then(|value| value.strip_prefix("bytes=")) {
        let (start, end) = spec
            .split_once('-')
            .ok_or_else(|| ApiError::bad_request("invalid_range"))?;
        let start: usize = start
            .parse()
            .map_err(|_| ApiError::bad_request("invalid_range"))?;
        let end: usize = if end.is_empty() {
            total.saturating_sub(1)
        } else {
            end.parse()
                .map_err(|_| ApiError::bad_request("invalid_range"))?
        };
        if start > end || end >= total {
            return Err(ApiError::new(
                StatusCode::RANGE_NOT_SATISFIABLE,
                "invalid_range",
                "Requested byte range is outside the blob",
            ));
        }
        return Ok((
            StatusCode::PARTIAL_CONTENT,
            [
                (header::CONTENT_TYPE, "application/octet-stream".into()),
                (
                    header::CONTENT_RANGE,
                    format!("bytes {start}-{end}/{total}"),
                ),
            ],
            bytes[start..=end].to_vec(),
        )
            .into_response());
    }
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/octet-stream")],
        bytes,
    )
        .into_response())
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

fn require_admin(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    let supplied = bearer(headers).unwrap_or_default();
    if supplied == state.admin_token {
        Ok(())
    } else {
        Err(ApiError::unauthorized())
    }
}

fn require_device(state: &AppState, headers: &HeaderMap) -> Result<Uuid, ApiError> {
    let device_id = headers
        .get("x-sonora-device")
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
    if bearer(headers).is_some_and(|token| token == state.admin_token) {
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
            sonora_sync_store::StoreError::Blob(_) => Self::bad_request(&error.to_string()),
            _ => Self::internal(error),
        }
    }
}
