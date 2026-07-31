//! Audio serving for DLNA renderers. Reuses the sync API's Range-capable file
//! streaming (`http::download_range_tracked`) and then rewrites the response
//! headers to what renderers require: a real MIME type instead of
//! `application/octet-stream`, plus the DLNA content features.
//!
//! Only content hashes present in the current library snapshot are served — the
//! blob store may briefly hold uploads or recently-removed audio that the visible
//! library no longer references.

use super::DlnaState;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use std::sync::Arc;

pub async fn media(
    State(state): State<Arc<DlnaState>>,
    Path(content_hash): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Ok(snapshot) = state.snapshot().await else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Some(track) = snapshot.track_by_hash(&content_hash) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let path = match state.app.store.blob_path_for_download(&content_hash) {
        Ok(Some(path)) => path,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(error) => {
            tracing::warn!(%error, "DLNA media path lookup failed");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let range = headers
        .get(header::RANGE)
        .and_then(|value| value.to_str().ok());
    let mut response =
        match crate::http::download_range_tracked(path, range, state.app.telemetry.clone()).await {
            Ok(response) => response,
            Err(error) => return error.into_response(),
        };
    let response_headers = response.headers_mut();
    response_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(super::mime::mime_for_extension(&track.extension)),
    );
    response_headers.insert(
        "contentFeatures.dlna.org",
        HeaderValue::from_static(super::mime::content_features(&track.extension)),
    );
    response_headers.insert(
        "transferMode.dlna.org",
        HeaderValue::from_static("Streaming"),
    );
    response
}
