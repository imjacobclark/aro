//! Comparing what Aro holds for a track against what its file actually says.
//!
//! Aro deliberately never let identification overwrite a file's tags, so the two drift: the
//! library shows a corrected title while the file on disk still carries whatever the rip
//! produced, and nothing surfaced that difference. Playing the track gives no clue, because
//! Aro shows its own value.
//!
//! Three layers exist per field — the file's tag, what identification decided, and any
//! manual override — and the listener sees only the resolved answer. This reports all of
//! them side by side, together with whether the file can still be reached, since a
//! difference nobody can act on is just noise.

use aro_sync_store::{HubStore, MetadataScopeTrack, StoreError};
use serde::Serialize;
use serde_json::Value;

/// Fields the metadata editor can change, and therefore the fields worth comparing.
pub const COMPARED_FIELDS: [&str; 7] = [
    "title",
    "artist",
    "album",
    "genre",
    "release_year",
    "track_number",
    "disc_number",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FieldVerdict {
    /// Both sides say the same thing.
    Agrees,
    /// Both have a value and they differ — the case worth acting on.
    Differs,
    /// Aro knows a value the file doesn't carry.
    MissingInFile,
    /// The file carries a value Aro doesn't hold.
    MissingInAro,
    /// Neither side has anything.
    Absent,
}

#[derive(Debug, Clone, Serialize)]
pub struct FieldDelta {
    pub field: &'static str,
    pub aro: Option<String>,
    pub file: Option<String>,
    pub verdict: FieldVerdict,
}

/// Where a track's audio actually is. Three states rather than a boolean because they mean
/// different things: Aro holding a copy keeps the track playable, while only a reachable
/// *original* can have corrected tags written into it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackAvailability {
    /// The original file is on disk and Aro also holds its own copy.
    OriginalAndCopy,
    /// Only the user's original — losing it loses the track.
    OriginalOnly,
    /// Only Aro's copy; the original has gone or was never reachable from here.
    CopyOnly,
    /// Neither. The track is catalogued but nothing can play it.
    Missing,
}

impl TrackAvailability {
    fn of(original_present: bool, hub_copy: bool) -> Self {
        match (original_present, hub_copy) {
            (true, true) => Self::OriginalAndCopy,
            (true, false) => Self::OriginalOnly,
            (false, true) => Self::CopyOnly,
            (false, false) => Self::Missing,
        }
    }

    /// Whether corrected tags can be written. Only an original can be written to — Aro's
    /// own copy is a derived artefact, and rewriting it would leave the file the user keeps
    /// untouched while silently diverging from it.
    pub fn is_writable(self) -> bool {
        matches!(self, Self::OriginalAndCopy | Self::OriginalOnly)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TrackDelta {
    pub content_hash: String,
    pub track_id: String,
    /// Aro's resolved title/artist/album, so a client can group and label without
    /// re-deriving the override rule.
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub availability: TrackAvailability,
    pub writable: bool,
    pub original_path: Option<String>,
    pub fields: Vec<FieldDelta>,
    /// Fields that differ or are missing on one side — what a UI counts to decide whether
    /// a track is worth showing at all.
    pub difference_count: usize,
}

/// Reads each track's file and compares it against Aro's values.
///
/// Tag reads are local file I/O, one open per track, so callers must bound the scope and
/// run this off the async runtime.
pub fn compare(store: &HubStore, tracks: Vec<MetadataScopeTrack>) -> Vec<TrackDelta> {
    tracks
        .into_iter()
        .map(|track| compare_one(store, track))
        .collect()
}

fn compare_one(_store: &HubStore, track: MetadataScopeTrack) -> TrackDelta {
    let path = track.original_path.as_deref().map(std::path::Path::new);
    // Only read a file that is actually there; a scan's view can be stale by the time this
    // runs, and a missing file is a fact worth reporting rather than an error.
    let present = path.is_some_and(|path| path.is_file());
    let tags = present
        .then(|| aro_track_id::tags::read_existing_tags(path.expect("present implies a path")));

    let aro = |field: &str| -> Option<String> {
        let map = track.metadata.as_object()?;
        let manual_set = map
            .get(&format!("manual_{field}_set"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let value = if manual_set {
            map.get(&format!("manual_{field}"))
        } else {
            map.get(field)
        }?;
        stringify(value)
    };

    let file = |field: &str| -> Option<String> {
        let tags = tags.as_ref()?;
        match field {
            "title" => tags.title.clone(),
            "artist" => tags.artist.clone(),
            "album" => tags.album.clone(),
            "genre" => tags.genre.clone(),
            "release_year" => tags.release_year.map(|value| value.to_string()),
            "track_number" => tags.track_number.map(|value| value.to_string()),
            "disc_number" => tags.disc_number.map(|value| value.to_string()),
            _ => None,
        }
    };

    let fields: Vec<FieldDelta> = COMPARED_FIELDS
        .iter()
        .map(|field| {
            let aro_value = aro(field).filter(|value| !value.trim().is_empty());
            let file_value = file(field).filter(|value| !value.trim().is_empty());
            let verdict = match (&aro_value, &file_value) {
                (Some(left), Some(right)) => {
                    // Compared case- and whitespace-insensitively: a difference of casing
                    // is not a correction worth showing anyone.
                    if left.trim().eq_ignore_ascii_case(right.trim()) {
                        FieldVerdict::Agrees
                    } else {
                        FieldVerdict::Differs
                    }
                }
                (Some(_), None) => FieldVerdict::MissingInFile,
                (None, Some(_)) => FieldVerdict::MissingInAro,
                (None, None) => FieldVerdict::Absent,
            };
            FieldDelta {
                field,
                aro: aro_value,
                file: file_value,
                verdict,
            }
        })
        .collect();

    let difference_count = fields
        .iter()
        .filter(|delta| {
            matches!(
                delta.verdict,
                FieldVerdict::Differs | FieldVerdict::MissingInFile | FieldVerdict::MissingInAro
            )
        })
        .count();
    let availability = TrackAvailability::of(present, track.hub_copy);

    TrackDelta {
        content_hash: track.content_hash,
        track_id: track.track_id.to_string(),
        title: aro("title"),
        artist: aro("artist"),
        album: aro("album"),
        availability,
        writable: availability.is_writable(),
        original_path: track.original_path,
        fields,
        difference_count,
    }
}

/// Renders a metadata value as the string a tag would carry. Numbers arrive as JSON numbers
/// from identification and as strings from the editor's text fields, and `1994` and `"1994"`
/// are the same year — comparing them as raw JSON would report a difference that isn't one.
fn stringify(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(flag) => Some(flag.to_string()),
        Value::Null => None,
        other => Some(other.to_string()),
    }
}

/// Aro's effective value for each comparable field — the manual override where one exists,
/// otherwise whatever identification or the original scan left. This is what the listener
/// sees, and therefore what gets written into the file.
pub fn effective_fields(metadata: &Value) -> serde_json::Map<String, Value> {
    let mut fields = serde_json::Map::new();
    let Some(map) = metadata.as_object() else {
        return fields;
    };
    for field in COMPARED_FIELDS {
        let manual_set = map
            .get(&format!("manual_{field}_set"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let value = if manual_set {
            map.get(&format!("manual_{field}"))
        } else {
            map.get(field)
        };
        if let Some(value) = value.filter(|value| !value.is_null()) {
            fields.insert(field.to_string(), value.clone());
        }
    }
    fields
}

/// What happened when Aro tried to write its metadata into one file.
#[derive(Debug, Clone, Serialize)]
pub struct WriteBackOutcome {
    pub content_hash: String,
    /// The hash after writing — the file's identity changes with its bytes.
    pub new_content_hash: Option<String>,
    pub written: bool,
    pub error: Option<String>,
}

/// Writes Aro's metadata into a track's own file, then moves the track's identity to match.
///
/// The file's SHA-256 is what identifies a track everywhere in Aro, and it covers the tags,
/// so a successful write always changes it. That migration is the dangerous half — see
/// [`HubStore::rekey_content_hash`] — and it happens in the same call so a written file can
/// never be left orphaned from its own history.
///
/// Refuses to touch a file whose bytes no longer match what Aro recorded. Writing tags into
/// a file that has already drifted would silently discard whatever changed it, and Aro has
/// no way to know what that was.
pub fn write_back_track(
    store: &HubStore,
    track: &MetadataScopeTrack,
    managed: bool,
) -> WriteBackOutcome {
    let mut outcome = WriteBackOutcome {
        content_hash: track.content_hash.clone(),
        new_content_hash: None,
        written: false,
        error: None,
    };
    let Some(path) = track.original_path.as_deref().map(std::path::Path::new) else {
        outcome.error = Some("no reachable original file".into());
        return outcome;
    };
    if !path.is_file() {
        outcome.error = Some("the original file is no longer there".into());
        return outcome;
    }
    if let Err(error) = aro_sync_core::verify_file(path, &track.content_hash) {
        outcome.error = Some(format!(
            "the file has changed since Aro last read it, so it was left alone: {error}"
        ));
        return outcome;
    }

    let fields = effective_fields(&track.metadata);
    if fields.is_empty() {
        outcome.error = Some("nothing to write".into());
        return outcome;
    }
    if let Err(error) = aro_track_id::tags::write_back(path, &fields) {
        outcome.error = Some(error.to_string());
        return outcome;
    }

    let (new_hash, _size) = match aro_sync_core::hash_file(path) {
        Ok(hashed) => hashed,
        Err(error) => {
            outcome.error = Some(format!("could not re-read the file after writing: {error}"));
            return outcome;
        }
    };
    if let Err(error) = store.rekey_content_hash(&track.content_hash, &new_hash) {
        outcome.error = Some(format!(
            "wrote the file but could not move its history: {error}"
        ));
        return outcome;
    }
    // A managed hub keeps its own copy, and playback serves that copy rather than the
    // original. Without re-importing, the file would show corrected tags in Finder while
    // Aro went on serving the bytes from before the edit — a divergence nothing would
    // surface.
    if managed && let Err(error) = store.import_managed(path) {
        outcome.error = Some(format!(
            "wrote the file, but Aro's own copy could not be refreshed: {error}"
        ));
    }

    outcome.new_content_hash = Some(new_hash);
    outcome.written = true;
    outcome
}

/// Resolves a scope and compares it, in one call.
pub fn for_scope(
    store: &HubStore,
    artist: Option<&str>,
    album: Option<&str>,
    content_hash: Option<&str>,
    limit: u32,
) -> Result<Vec<TrackDelta>, StoreError> {
    let tracks = store.metadata_scope_tracks(artist, album, content_hash, limit)?;
    Ok(compare(store, tracks))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn track(metadata: Value, original_path: Option<&str>, hub_copy: bool) -> MetadataScopeTrack {
        MetadataScopeTrack {
            track_id: uuid::Uuid::nil(),
            content_hash: "a".repeat(64),
            metadata,
            original_path: original_path.map(str::to_owned),
            hub_copy,
        }
    }

    /// The three availability states drive what the UI offers, and only a reachable
    /// original can be written to — Aro's own copy is derived, and rewriting it would leave
    /// the user's file untouched while silently diverging from it.
    #[test]
    fn availability_distinguishes_the_original_from_aros_copy() {
        assert_eq!(
            TrackAvailability::of(true, true),
            TrackAvailability::OriginalAndCopy
        );
        assert_eq!(
            TrackAvailability::of(true, false),
            TrackAvailability::OriginalOnly
        );
        assert_eq!(
            TrackAvailability::of(false, true),
            TrackAvailability::CopyOnly
        );
        assert_eq!(
            TrackAvailability::of(false, false),
            TrackAvailability::Missing
        );

        assert!(TrackAvailability::OriginalOnly.is_writable());
        assert!(TrackAvailability::OriginalAndCopy.is_writable());
        assert!(
            !TrackAvailability::CopyOnly.is_writable(),
            "Aro's own copy is not the user's file and must not be written"
        );
        assert!(!TrackAvailability::Missing.is_writable());
    }

    /// A manual correction is what the listener sees, so it is what a difference must be
    /// measured against — comparing the value underneath would report the file as matching
    /// something the user has already overridden.
    #[test]
    fn comparison_uses_the_value_the_listener_actually_sees() {
        let store = HubStore::open(tempfile::tempdir().unwrap().path()).unwrap();
        let deltas = compare(
            &store,
            vec![track(
                json!({
                    "title": "Untitled",
                    "manual_title": "Real Title",
                    "manual_title_set": true,
                }),
                None,
                true,
            )],
        );
        let title = deltas[0]
            .fields
            .iter()
            .find(|delta| delta.field == "title")
            .unwrap();
        assert_eq!(title.aro.as_deref(), Some("Real Title"));
    }

    /// A file whose bytes no longer match what Aro recorded has been changed by something
    /// else — another tagger, a re-rip, a sync. Writing Aro's values over it would discard
    /// that change with no way to know what it was, so the file is left exactly as found.
    #[test]
    fn a_file_that_has_drifted_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let store = HubStore::open(dir.path()).unwrap();
        let path = dir.path().join("drifted.flac");
        std::fs::write(&path, b"these are not the bytes aro recorded").unwrap();
        let before = std::fs::read(&path).unwrap();

        let outcome = write_back_track(
            &store,
            &track(
                json!({"title": "Corrected Title"}),
                Some(path.to_str().unwrap()),
                false,
            ),
            false,
        );

        assert!(!outcome.written);
        assert!(
            outcome.error.unwrap().contains("changed since"),
            "the refusal must say why, so the user can go and look"
        );
        assert_eq!(
            std::fs::read(&path).unwrap(),
            before,
            "a refused write must not have touched the file"
        );
    }

    /// Nothing in Aro writes tags on its own — write-back is always user-initiated — which
    /// is the only reason re-identifying a written file cannot loop back into another write.
    /// A track with no values to write must therefore stop rather than rewrite a file with
    /// nothing, changing its hash for no gain.
    #[test]
    fn a_track_with_nothing_to_write_does_not_touch_its_file() {
        let dir = tempfile::tempdir().unwrap();
        let store = HubStore::open(dir.path()).unwrap();
        let path = dir.path().join("empty-metadata.flac");
        std::fs::write(&path, b"audio").unwrap();
        let (hash, _size) = aro_sync_core::hash_file(&path).unwrap();

        let mut scope = track(json!({}), Some(path.to_str().unwrap()), false);
        scope.content_hash = hash;
        let outcome = write_back_track(&store, &scope, false);

        assert!(!outcome.written);
        assert_eq!(outcome.error.as_deref(), Some("nothing to write"));
        assert_eq!(std::fs::read(&path).unwrap(), b"audio");
    }

    /// Years arrive as JSON numbers from identification and as strings from the editor's
    /// text fields. Reporting `1994` as different from `"1994"` would fill the screen with
    /// differences that are not differences.
    #[test]
    fn numbers_and_strings_are_not_treated_as_a_difference() {
        assert_eq!(stringify(&json!(1994)).as_deref(), Some("1994"));
        assert_eq!(stringify(&json!("1994")).as_deref(), Some("1994"));
        assert_eq!(stringify(&Value::Null), None);
    }

    /// A file Aro cannot read is a fact to report, not an error, and every field is then
    /// "Aro knows this, the file doesn't" rather than a spurious disagreement.
    #[test]
    fn an_unreachable_file_reports_missing_rather_than_differing() {
        let store = HubStore::open(tempfile::tempdir().unwrap().path()).unwrap();
        let deltas = compare(
            &store,
            vec![track(
                json!({"title": "Known Title", "artist": "Known Artist"}),
                Some("/nonexistent/file.flac"),
                true,
            )],
        );
        let delta = &deltas[0];
        assert_eq!(delta.availability, TrackAvailability::CopyOnly);
        assert!(!delta.writable, "a missing original cannot be written to");
        let title = delta
            .fields
            .iter()
            .find(|field| field.field == "title")
            .unwrap();
        assert_eq!(title.verdict, FieldVerdict::MissingInFile);
    }
}
