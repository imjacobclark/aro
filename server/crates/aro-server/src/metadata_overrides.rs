//! Manual metadata corrections — the values a listener sets by hand.
//!
//! These are Aro's golden master: identification and rescans never overwrite them. The
//! logic lived in the control module, which is Unix-only because it serves a Unix socket,
//! while the HTTP API used it on every platform — so the Windows build had been broken for
//! as long as remote clients have been able to edit metadata. Nothing here is
//! platform-specific, so nothing here is gated.

use crate::http::AppState;
use anyhow::Result;
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

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
