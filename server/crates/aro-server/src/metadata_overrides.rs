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

/// Fields written verbatim, without the `manual_` prefix the corrections below carry.
///
/// A correction and a preference are different things. "The artist is really Talk Talk"
/// overrides what identification found, so it is stored as `manual_artist` + a
/// `manual_artist_set` flag that later identification runs must not tread on. Marking a
/// track as loved competes with nothing — there is no identified value for it — so it is
/// simply `favourite`, exactly as the macOS client writes it. Keeping the two sets apart
/// is what stops a favourite from being silently reverted by `reset`, which is meant to
/// undo corrections and hand a track back to identification.
const DIRECT_FIELDS: [&str; 1] = ["favourite"];

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
    // The same for every track in the request, so it is built once: selecting an album and
    // correcting its artist is one payload applied to each of its tracks.
    let payload = manual_metadata_payload(&request.fields, request.reset, &FIELDS);
    if payload.is_empty() {
        return Ok(0);
    }
    let field_versions: std::collections::BTreeMap<_, _> = payload
        .keys()
        .map(|field| (field.clone(), timestamp.clone()))
        .collect();

    let mut operations = Vec::new();
    for hash in request.content_hashes {
        let Some(track_id) = state.store.track_id_for_hash(&hash)? else {
            continue;
        };
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
            payload: Value::Object(payload.clone()),
            field_versions: field_versions.clone(),
        });
    }
    let count = operations.len();
    state.store.append_operations(&operations)?;
    Ok(count)
}

/// Turns a request's fields into one track's CRDT payload. Split out from the loop above
/// because this — which field earns which prefix, and what `reset` does and does not undo
/// — is the whole of the decision, and it is worth testing without a hub behind it.
fn manual_metadata_payload(
    fields: &serde_json::Map<String, Value>,
    reset: bool,
    corrections: &[&str],
) -> serde_json::Map<String, Value> {
    let mut payload = serde_json::Map::new();
    if reset {
        for field in corrections {
            payload.insert(format!("manual_{field}_set"), Value::Bool(false));
        }
        payload.insert("manual_artwork_set".into(), Value::Bool(false));
        return payload;
    }
    for (field, value) in fields {
        if corrections.contains(&field.as_str()) {
            payload.insert(format!("manual_{field}"), value.clone());
            payload.insert(format!("manual_{field}_set"), Value::Bool(true));
        } else if DIRECT_FIELDS.contains(&field.as_str()) {
            payload.insert(field.clone(), value.clone());
        }
    }
    // Artwork the listener picked by hand. The base64 never reaches the operation log:
    // `HubStore::append_operations` swaps it for a content-addressed blob hash on the way
    // in (see `prepare_manual_artwork`), so one cover shared by a whole album is stored
    // once rather than per track.
    if let Some(artwork) = fields.get("artwork_base64") {
        payload.insert("manual_artwork_base64".into(), artwork.clone());
        payload.insert("manual_artwork_set".into(), Value::Bool(true));
    }
    payload
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const CORRECTIONS: [&str; 7] = [
        "title",
        "artist",
        "album",
        "genre",
        "release_year",
        "track_number",
        "disc_number",
    ];

    fn fields(value: Value) -> serde_json::Map<String, Value> {
        match value {
            Value::Object(map) => map,
            _ => panic!("test fields must be an object"),
        }
    }

    #[test]
    fn a_correction_is_stored_under_its_manual_name_with_a_set_flag() {
        let payload =
            manual_metadata_payload(&fields(json!({"artist": "Talk Talk"})), false, &CORRECTIONS);

        assert_eq!(payload["manual_artist"], json!("Talk Talk"));
        assert_eq!(payload["manual_artist_set"], json!(true));
        assert!(
            !payload.contains_key("artist"),
            "a correction must not also be written unprefixed, or identification would overwrite it"
        );
    }

    /// A favourite is a preference, not a correction: nothing identified it, so it is
    /// written under its own name and read straight back by `catalog_page`.
    #[test]
    fn a_favourite_is_stored_verbatim() {
        let payload =
            manual_metadata_payload(&fields(json!({"favourite": true})), false, &CORRECTIONS);

        assert_eq!(payload["favourite"], json!(true));
        assert!(!payload.contains_key("manual_favourite"));
        assert!(!payload.contains_key("manual_favourite_set"));
    }

    #[test]
    fn unfavouriting_is_a_write_of_false_rather_than_an_absence() {
        let payload =
            manual_metadata_payload(&fields(json!({"favourite": false})), false, &CORRECTIONS);

        assert_eq!(
            payload["favourite"],
            json!(false),
            "an empty payload would be skipped entirely, leaving the track loved"
        );
    }

    /// `reset` means "forget my corrections and let identification decide again". A
    /// favourite was never identification's to decide, so it survives.
    #[test]
    fn reset_clears_every_correction_and_leaves_favourites_alone() {
        let payload =
            manual_metadata_payload(&fields(json!({"favourite": true})), true, &CORRECTIONS);

        for field in CORRECTIONS {
            assert_eq!(payload[&format!("manual_{field}_set")], json!(false));
        }
        assert_eq!(payload["manual_artwork_set"], json!(false));
        assert!(
            !payload.contains_key("favourite"),
            "reset must not silently unlove a track"
        );
    }

    #[test]
    fn chosen_artwork_travels_as_base64_for_the_store_to_deduplicate() {
        let payload = manual_metadata_payload(
            &fields(json!({"artwork_base64": "aGVsbG8="})),
            false,
            &CORRECTIONS,
        );

        assert_eq!(payload["manual_artwork_base64"], json!("aGVsbG8="));
        assert_eq!(payload["manual_artwork_set"], json!(true));
    }

    #[test]
    fn unknown_fields_are_ignored_rather_than_written_through() {
        let payload = manual_metadata_payload(
            &fields(json!({"content_hash": "deadbeef", "hidden": true})),
            false,
            &CORRECTIONS,
        );

        assert!(
            payload.is_empty(),
            "a client must not be able to write arbitrary keys into track metadata"
        );
    }
}
