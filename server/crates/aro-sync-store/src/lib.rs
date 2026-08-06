use aro_sync_core::{BlobError, hash_file, validate_hash, verify_file};
use aro_sync_protocol::{
    CatalogPage, CatalogTrack, ConflictChoice, DeviceSummary, ExportManifest, ExportTrack,
    FieldConflict, HybridTimestamp, JoinCommitRequest, JoinPreview, JoinPreviewRequest,
    ManifestEntry, Operation, PlaybackActivitySnapshot, PlaybackActivityState, SequencedOperation,
    SourceHealthReport, TopologyPlaybackActivity, VersionedValue,
};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::{
    fs::{self, OpenOptions},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::Arc,
};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Debug, serde::Serialize)]
pub struct SourceFolder {
    pub source_id: Uuid,
    pub name: String,
    pub path: PathBuf,
    pub available: bool,
    pub watching: bool,
    pub last_scan_at: Option<String>,
    pub last_error: Option<String>,
    pub song_count: u64,
    pub missing_count: u64,
}

#[derive(Clone, Debug)]
pub struct SourceFile {
    pub relative_path: String,
    pub track_id: Uuid,
    pub content_hash: String,
    pub size: u64,
    pub modified_millis: i64,
    pub available: bool,
}

/// A cached raw response pair from a prior AcoustID/MusicBrainz identification lookup,
/// keyed by fingerprint. Local-node cache only, deliberately not part of the CRDT
/// operation log — each node can re-derive it, and it never needs to sync.
#[derive(Clone, Debug)]
pub struct IdentificationCacheEntry {
    pub acoustid_response: Option<Value>,
    pub musicbrainz_response: Option<Value>,
    /// Which shape of `aro_track_id::{acoustid, musicbrainz}` response types this row was
    /// captured with — see `aro_track_id::CACHE_SCHEMA_VERSION`. Rows written before this
    /// column existed default to `0`, which is guaranteed to be older than any real version
    /// and therefore always treated as stale.
    pub schema_version: u32,
    pub refreshed_at: i64,
}

/// One row of `release_group_affinity`, as returned by
/// [`HubStore::release_group_affinity_rows`].
#[derive(Clone, Debug)]
pub struct ReleaseGroupAffinityRow {
    pub release_group_id: String,
    pub release_title: Option<String>,
    pub track_count: i64,
}

/// A cached raw `ws/2/release/{id}` response, keyed by release id. Unlike
/// `identification_cache` (which can legitimately cache a "no match" negative result), a
/// release cache row only ever exists once a release has actually been successfully fetched
/// — so `response` is required, not optional. Local-node cache only, like
/// `IdentificationCacheEntry`, and for the same reason: each node can re-derive it, and it
/// never needs to sync.
#[derive(Clone, Debug)]
pub struct ReleaseCacheEntry {
    pub response: Value,
    pub schema_version: u32,
    pub refreshed_at: i64,
}

/// A cached raw `ws/2/recording/{id}` response, keyed by recording id. Distinct from
/// `identification_cache` (keyed by fingerprint, one recording per row — the per-file
/// best-match pick) and `musicbrainz_release_cache` (keyed by release id, a shortlisted
/// candidate's full tracklist): this caches the *other* candidate recordings a group match
/// consults to build its release shortlist (see `aro_track_id::queue::fetch_recording_cached`),
/// so retrying a rejected group doesn't re-pay the same MusicBrainz requests every pass.
#[derive(Clone, Debug)]
pub struct RecordingCacheEntry {
    pub response: Value,
    pub schema_version: u32,
    pub refreshed_at: i64,
}

/// One scanned, available file within a folder, as returned by [`HubStore::folder_members`].
#[derive(Clone, Debug)]
pub struct FolderMember {
    pub path: PathBuf,
    pub content_hash: String,
}

/// One live track eligible for auto-playlist generation, keyed by content hash — the only
/// identifier shared with client libraries (see [`IdentificationResult`]'s doc comment).
#[derive(Clone, Debug)]
pub struct PlaylistSeedTrack {
    pub content_hash: String,
    /// From the CRDT-materialized `tracks.metadata` `favourite` field.
    pub favourite: bool,
    /// Canonical mood vocabulary from `identification_results.mood_tags` — empty when the
    /// track hasn't been identified or no folksonomy tag matched a known mood.
    pub mood_tags: Vec<String>,
    /// MusicBrainz's curated genres for this track. Far denser than [`Self::mood_tags`],
    /// which only exist where a folksonomy tag happened to match a small keyword table —
    /// on the reference library 215 tracks carry genres across 105 distinct names, against
    /// 26 with any mood at all.
    pub genres: Vec<String>,
    /// Milliseconds since epoch this track was first seen — the minimum
    /// `field_versions` timestamp across all its CRDT fields, since a freshly
    /// scanned track has every field written at (approximately) the same instant.
    /// `None` for a track with no field versions recorded yet (shouldn't normally
    /// happen for a live track, but the CRDT payload is technically optional).
    /// Drives "Fresh Finds" (added recently, unplayed).
    pub first_seen_at_millis: Option<i64>,
    /// From `tracks.metadata`'s `artist`/`album`/`release_year` fields — drives
    /// artist- and year-grouped playlists ("More From X", "Favourite Artists",
    /// "Hits of `<year>`"). `None` when the track has no tag for that field.
    pub artist: Option<String>,
    pub album: Option<String>,
    pub release_year: Option<i64>,
    /// The JSON serialization of this track's `aro_track_id::audio_features::AudioFeatures`
    /// (tempo, energy, brightness, dynamic range, MFCC/chroma vector), if it's been
    /// analyzed — kept as an opaque string here rather than the real type, since that
    /// type lives in `aro-track-id`, which depends on this crate (not the reverse).
    /// `aro-server`'s `playlists` module decodes it. `None` until analysis completes.
    pub audio_features_json: Option<String>,
}

/// Aggregated `listening_events` stats for one track, keyed by content hash — feeds
/// Tier 1 behavioural playlists (decayed Heavy Rotation, Forgotten Favourites,
/// skip-aware Deep Cuts, time-of-day mixes).
#[derive(Clone, Debug, Default)]
pub struct ListeningEventSummary {
    pub play_count: i64,
    pub skip_count: i64,
    pub completed_count: i64,
    /// Seconds since epoch of the most recent play.
    pub last_played_at: f64,
    /// Exponential-decay-weighted play count (45-day half-life): each play
    /// contributes `0.5^(age_days / 45)`, so recent listening counts far more than
    /// old listening — this is what "Heavy Rotation" should rank by, not a raw
    /// lifetime tally.
    pub decayed_affinity: f64,
    /// Play counts bucketed by UTC hour-of-day (index 0-23) `started_at` falls in.
    /// The generator combines this with a client-supplied UTC offset to bucket into
    /// the *requester's* local morning/evening, not the hub's.
    pub hour_histogram: [i64; 24],
    /// Plays whose `started_at` falls in the hub's current UTC calendar month —
    /// drives "Your `<Month>` Replay". Same UTC-vs-local caveat as
    /// `hour_histogram`: a play just before/after local midnight near a month
    /// boundary can land in the "wrong" month for a listener outside UTC. Not worth
    /// correcting for a monthly-granularity feature the way `hour_histogram` is for
    /// `Morning`/`Late Night`.
    pub current_month_play_count: i64,
    /// UTC calendar year of this track's earliest/most recent logged play — drives
    /// "Time Capsule" (tracks whose `last_played_year` is now several years stale
    /// despite meaningful lifetime `play_count`). `None` until at least one play is
    /// recorded (same lifetime as the rest of this summary, which only exists for
    /// content hashes with at least one event).
    pub first_played_year: Option<i32>,
    pub last_played_year: Option<i32>,
}

/// Everything [`HubStore::playlist_seeds`] can tell an auto-playlist generator, all keyed
/// by content hash.
#[derive(Clone, Debug, Default)]
pub struct PlaylistSeeds {
    /// Every live, content-addressed track, in stable `hub_track_id` order.
    pub tracks: Vec<PlaylistSeedTrack>,
    /// Listening-event aggregates, present only for content hashes with at least one
    /// logged event — absence means never played.
    pub listening: HashMap<String, ListeningEventSummary>,
    /// How far through tracks were actually played, derived from playback heartbeats.
    ///
    /// This is not broader coverage than [`Self::listening`] — on the reference library it
    /// spans 39 tracks against the event log's 48. It is *deeper*: heartbeats carry the
    /// position reached, so a track started and left after forty seconds is distinguishable
    /// from one played through, which a play count and a skip flag cannot express. That
    /// library records 12 skips but 33 abandoned sessions.
    pub engagement: HashMap<String, EngagementSummary>,
}

/// What a listener actually did with a track, reconstructed from playback heartbeats.
///
/// A listening event says a track was played; this says whether it was *listened to*.
/// Abandonment is the useful signal a play count cannot express — a track stopped forty
/// seconds in was not enjoyed, however many times it was started.
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct EngagementSummary {
    /// Distinct playback sessions observed.
    pub sessions: i64,
    /// Sessions that reached the end, or near enough to count.
    pub completed_sessions: i64,
    /// Sessions abandoned early — started, then left.
    pub abandoned_sessions: i64,
    /// Mean fraction of the track reached across sessions, in `0.0...1.0`.
    pub mean_fraction: f64,
    /// Seconds since epoch of the most recent activity.
    pub last_observed_at: f64,
}

impl EngagementSummary {
    /// Fraction of sessions that ran to completion. `None` below a couple of sessions,
    /// where the ratio is noise rather than a rate — one abandoned play out of one is not
    /// evidence a track is disliked.
    pub fn completion_rate(&self) -> Option<f64> {
        (self.sessions >= 2).then(|| self.completed_sessions as f64 / self.sessions as f64)
    }
}

/// The outcome of identifying one file, keyed by `content_hash` rather than
/// `hub_track_id`. Content hash is the only identifier genuinely shared between this
/// database and the macOS app's separate local library catalog (their track IDs are
/// generated independently and never coincide) — so identification results are kept
/// here, outside the CRDT `tracks` table, and pulled by content hash rather than
/// merged through the operation log.
#[derive(Clone, Debug, serde::Serialize)]
pub struct IdentificationResult {
    pub content_hash: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub artwork_url: Option<String>,
    pub musicbrainz_recording_id: Option<String>,
    pub acoustid_id: Option<String>,
    pub identified_at: i64,
    /// How this result was produced — `"per_file"`, `"group"`, or `"reconcile"` (see
    /// `aro_track_id::queue`). `None` for rows written before this column existed.
    pub resolution_source: Option<String>,
    /// The `album::GroupMatch::score`/analogous confidence this result was written with,
    /// if it came from a scored path — `None` for a per-file result, which has no single
    /// comparable score.
    pub resolution_score: Option<f64>,
    /// Which `aro_track_id::IDENTIFICATION_GENERATION` this result was last written or
    /// confirmed at. Defaults to `0` for rows predating this column (see the migration's
    /// `DEFAULT`), which is below any real generation and therefore eligible for exactly
    /// one reconcile pass.
    pub resolution_generation: i64,
    pub release_id: Option<String>,
    pub release_group_id: Option<String>,
    /// MusicBrainz's curated genre subset for this recording, JSON-array-encoded (e.g.
    /// `["dream pop","shoegaze"]`) — see `aro_track_id::musicbrainz::canonicalize_tags`.
    /// `None` for rows predating this column, or when MusicBrainz had no genre data.
    pub musicbrainz_genres: Option<String>,
    /// Up to 2 canonical mood tags (from a small fixed vocabulary — "relaxed", "energetic",
    /// etc.) derived from MusicBrainz folksonomy tags, JSON-array-encoded. Drives
    /// auto-generated mood playlists client-side. `None` for rows predating this column, or
    /// when no folksonomy tag matched a known mood.
    pub mood_tags: Option<String>,
}

/// Shared row-mapper for the three `identification_results` read paths — keeps the column
/// order/count in exactly one place rather than duplicated per query.
fn identification_result_from_row(row: &rusqlite::Row) -> rusqlite::Result<IdentificationResult> {
    Ok(IdentificationResult {
        content_hash: row.get(0)?,
        title: row.get(1)?,
        artist: row.get(2)?,
        album: row.get(3)?,
        artwork_url: row.get(4)?,
        musicbrainz_recording_id: row.get(5)?,
        acoustid_id: row.get(6)?,
        identified_at: row.get(7)?,
        resolution_source: row.get(8)?,
        resolution_score: row.get(9)?,
        resolution_generation: row.get(10)?,
        release_id: row.get(11)?,
        release_group_id: row.get(12)?,
        musicbrainz_genres: row.get(13)?,
        mood_tags: row.get(14)?,
    })
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Blob(#[from] BlobError),
    #[error("upload offset mismatch: expected {expected}, received {received}")]
    OffsetMismatch { expected: u64, received: u64 },
    #[error("blob size mismatch")]
    SizeMismatch,
    #[error("blob is still referenced")]
    BlobReferenced,
    #[error("join preview not found or already committed")]
    JoinPreviewNotFound,
    #[error("manual artwork is invalid or exceeds 10 MiB")]
    InvalidManualArtwork,
}

#[derive(Clone)]
pub struct HubStore {
    connection: Arc<Mutex<Connection>>,
    root: Arc<PathBuf>,
}

/// Formats that always reproduce the source exactly.
const LOSSLESS_CODECS: [&str; 7] = ["alac", "flac", "wav", "aiff", "aif", "ape", "wv"];
/// Formats that never do.
const LOSSY_CODECS: [&str; 6] = ["mp3", "aac", "ogg", "vorbis", "opus", "wma"];
/// `m4a`/`mp4` name a *container*, which can hold lossless ALAC or lossy AAC, so the name
/// alone cannot decide. The ratio of actual to uncompressed bitrate can: ALAC lands around
/// 70% of uncompressed, while even a generous AAC sits far below — the reference library's
/// ALAC files report 1,012 kbps against 1,411 kbps uncompressed, and its MP3s 320 kbps with
/// no bit depth at all.
const LOSSLESS_MIN_BITRATE_RATIO: f64 = 0.4;

/// Whether a track's audio survived encoding intact.
///
/// Deliberately conservative: without the evidence to judge, a track is not claimed as
/// lossless. Overstating fidelity is the worse error for a statistic whose whole purpose is
/// telling a listener what they actually hold.
fn is_lossless(codec: &str, metadata: &serde_json::Map<String, Value>) -> bool {
    if LOSSLESS_CODECS.contains(&codec) {
        return true;
    }
    if LOSSY_CODECS.contains(&codec) {
        return false;
    }
    let number = |key: &str| metadata.get(key).and_then(Value::as_f64);
    let (Some(depth), Some(rate), Some(bitrate)) = (
        number("bit_depth"),
        number("sample_rate"),
        number("bitrate"),
    ) else {
        return false;
    };
    let channels = number("channel_count").unwrap_or(2.0).max(1.0);
    let uncompressed = rate * depth * channels;
    uncompressed > 0.0 && bitrate / uncompressed >= LOSSLESS_MIN_BITRATE_RATIO
}

/// One track's metadata as Aro holds it, together with where its file is and whether that
/// file can still be reached.
///
/// Availability is deliberately three states rather than a boolean, because the difference
/// matters to the listener and to what Aro is allowed to do. Aro holding a copy means the
/// track plays; the *original* being reachable is a separate question, and only that
/// permits writing corrected tags back.
#[derive(Clone, Debug)]
pub struct MetadataScopeTrack {
    pub track_id: Uuid,
    pub content_hash: String,
    /// The full CRDT metadata map, so callers can apply the manual-override rule
    /// themselves rather than this returning seven separate resolved fields.
    pub metadata: Value,
    /// Absolute path to the user's own file, if a scan currently says it is there.
    pub original_path: Option<String>,
    /// Whether the hub holds its own copy, which is what keeps a track playable when the
    /// original goes away.
    pub hub_copy: bool,
}

impl HubStore {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join("blobs"))?;
        fs::create_dir_all(root.join("uploads"))?;
        let connection = Connection::open(root.join("hub.sqlite3"))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        migrate(&connection)?;
        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
            root: Arc::new(root),
        })
    }

    pub fn root(&self) -> &Path {
        self.root.as_ref()
    }

    pub fn append_operations(
        &self,
        operations: &[Operation],
    ) -> Result<Vec<SequencedOperation>, StoreError> {
        let operations = self.prepare_manual_artwork(operations)?;
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let mut accepted = Vec::new();
        for operation in &operations {
            let payload = serde_json::to_string(operation).expect("operation serialization");
            let inserted = transaction.execute(
                r#"
                INSERT OR IGNORE INTO operations
                    (operation_id, device_id, entity_type, entity_id, kind, payload, accepted_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, unixepoch())
                "#,
                params![
                    operation.operation_id.to_string(),
                    operation.device_id.to_string(),
                    operation.entity_type,
                    operation.entity_id,
                    operation.kind,
                    payload,
                ],
            )?;
            let sequence: u64 = transaction.query_row(
                "SELECT sequence FROM operations WHERE operation_id = ?1",
                [operation.operation_id.to_string()],
                |row| row.get(0),
            )?;
            if inserted > 0 {
                materialize_operation(&transaction, operation)?;
            }
            accepted.push(SequencedOperation {
                sequence,
                operation: operation.clone(),
            });
        }
        transaction.commit()?;
        Ok(accepted)
    }

    /// Replaces transport-only base64 artwork with a content-addressed blob
    /// reference before the operation enters the durable CRDT log. This keeps
    /// replicated metadata small while allowing any metadata editor path (local
    /// control socket or remote exchange) to use the same operation shape.
    fn prepare_manual_artwork(
        &self,
        operations: &[Operation],
    ) -> Result<Vec<Operation>, StoreError> {
        const MAX_ARTWORK_BYTES: usize = 10 * 1024 * 1024;
        let mut prepared = operations.to_vec();
        for operation in &mut prepared {
            if operation.entity_type != "track_state" {
                continue;
            }
            let Value::Object(payload) = &mut operation.payload else {
                continue;
            };
            let Some(Value::String(encoded)) = payload.remove("manual_artwork_base64") else {
                continue;
            };
            let bytes = BASE64
                .decode(encoded)
                .map_err(|_| StoreError::InvalidManualArtwork)?;
            if bytes.is_empty() || bytes.len() > MAX_ARTWORK_BYTES {
                return Err(StoreError::InvalidManualArtwork);
            }
            let hash = hex::encode(Sha256::digest(&bytes));
            if !self.blob_path(&hash).is_file() {
                let upload = self.upload_path(&hash);
                if upload.exists() {
                    fs::remove_file(&upload)?;
                }
                fs::write(&upload, &bytes)?;
                self.commit_blob(&hash, bytes.len() as u64)?;
            }
            payload.insert("manual_artwork_hash".into(), Value::String(hash));
            let version = operation
                .field_versions
                .remove("manual_artwork_base64")
                .or_else(|| operation.field_versions.get("manual_artwork_set").cloned());
            if let Some(version) = version {
                operation
                    .field_versions
                    .insert("manual_artwork_hash".into(), version);
            }
        }
        Ok(prepared)
    }

    pub fn changes_after(
        &self,
        after_sequence: u64,
        limit: u32,
    ) -> Result<Vec<SequencedOperation>, StoreError> {
        // An upload-only exchange says so with an explicit zero rather than by
        // parking the cursor somewhere unreachable.
        if limit == 0 {
            return Ok(Vec::new());
        }
        // SQLite's INTEGER is signed, so binding a u64 above i64::MAX fails the
        // conversion outright rather than simply matching no rows. Older clients
        // still send u64::MAX to mean "return nothing to me", and a cursor that
        // large can never match a real sequence anyway, so saturating here is
        // lossless and keeps any client's input from 500ing the hub.
        let after_sequence = after_sequence.min(i64::MAX as u64);
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT sequence, payload
            FROM operations
            WHERE sequence > ?1
            ORDER BY sequence
            LIMIT ?2
            "#,
        )?;
        let rows = statement.query_map(params![after_sequence, limit.clamp(1, 1000)], |row| {
            let sequence = row.get(0)?;
            let json: String = row.get(1)?;
            let operation = serde_json::from_str(&json).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    json.len(),
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })?;
            Ok(SequencedOperation {
                sequence,
                operation,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn latest_sequence(&self) -> Result<u64, StoreError> {
        Ok(self.connection.lock().query_row(
            "SELECT COALESCE(MAX(sequence), 0) FROM operations",
            [],
            |row| row.get(0),
        )?)
    }

    pub fn content_hashes(&self) -> Result<HashSet<String>, StoreError> {
        let connection = self.connection.lock();
        let mut statement =
            connection.prepare("SELECT content_hash FROM tracks WHERE content_hash IS NOT NULL")?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?)
    }

    pub fn track_metadata_has_field(
        &self,
        track_id: Uuid,
        field: &str,
    ) -> Result<bool, StoreError> {
        let metadata: Option<String> = self
            .connection
            .lock()
            .query_row(
                "SELECT metadata FROM tracks WHERE hub_track_id = ?1",
                [track_id.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        Ok(metadata
            .and_then(|value| serde_json::from_str::<serde_json::Map<String, Value>>(&value).ok())
            .is_some_and(|values| values.get(field).is_some_and(|value| !value.is_null())))
    }

    pub fn snapshot_tracks(
        &self,
        offset: u64,
        limit: u32,
    ) -> Result<Vec<ManifestEntry>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT hub_track_id, content_hash, metadata, field_versions, tombstoned_at
            FROM tracks
            WHERE purged_at IS NULL
            ORDER BY hub_track_id
            LIMIT ?1 OFFSET ?2
            "#,
        )?;
        let rows = statement.query_map(params![limit.clamp(1, 1000), offset], |row| {
            let hub_id: String = row.get(0)?;
            let metadata: String = row.get(2)?;
            let timestamps: String = row.get(3)?;
            let values: serde_json::Map<String, Value> =
                serde_json::from_str(&metadata).unwrap_or_default();
            let versions: BTreeMap<String, aro_sync_protocol::HybridTimestamp> =
                serde_json::from_str(&timestamps).unwrap_or_default();
            let fields = values
                .into_iter()
                .filter_map(|(field, value)| {
                    versions
                        .get(&field)
                        .cloned()
                        .map(|timestamp| (field, VersionedValue { value, timestamp }))
                })
                .collect();
            Ok(ManifestEntry {
                local_track_id: hub_id.clone(),
                hub_track_id: Uuid::parse_str(&hub_id).ok(),
                content_hash: row.get(1)?,
                fields,
                tombstoned: row.get::<_, Option<i64>>(4)?.is_some(),
            })
        })?;
        rows.collect::<Result<_, _>>().map_err(Into::into)
    }

    /// Presentation-ready catalog page. The query is deliberately executed in
    /// SQLite so a streaming client never needs to download or group the whole
    /// library just to render one screen.
    pub fn catalog_page(
        &self,
        cursor: u64,
        limit: u32,
        query: Option<&str>,
        sort: Option<&str>,
    ) -> Result<CatalogPage, StoreError> {
        let connection = self.connection.lock();
        let limit = limit.clamp(1, 200);
        let search = query
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| format!("%{}%", value));
        let order = match sort.unwrap_or("title") {
            "artist" => "LOWER(COALESCE(CASE WHEN json_extract(t.metadata, '$.manual_artist_set') = 1 THEN json_extract(t.metadata, '$.manual_artist') ELSE json_extract(t.metadata, '$.artist') END, '')),
                LOWER(COALESCE(CASE WHEN json_extract(t.metadata, '$.manual_album_set') = 1 THEN json_extract(t.metadata, '$.manual_album') ELSE json_extract(t.metadata, '$.album') END, '')),
                COALESCE(CAST(CASE WHEN json_extract(t.metadata, '$.manual_disc_number_set') = 1 THEN json_extract(t.metadata, '$.manual_disc_number') ELSE json_extract(t.metadata, '$.disc_number') END AS INTEGER), 0),
                COALESCE(CAST(CASE WHEN json_extract(t.metadata, '$.manual_track_number_set') = 1 THEN json_extract(t.metadata, '$.manual_track_number') ELSE json_extract(t.metadata, '$.track_number') END AS INTEGER), 0),
                t.hub_track_id",
            "album" => "LOWER(COALESCE(CASE WHEN json_extract(t.metadata, '$.manual_album_set') = 1 THEN json_extract(t.metadata, '$.manual_album') ELSE json_extract(t.metadata, '$.album') END, '')),
                LOWER(COALESCE(CASE WHEN json_extract(t.metadata, '$.manual_artist_set') = 1 THEN json_extract(t.metadata, '$.manual_artist') ELSE json_extract(t.metadata, '$.artist') END, '')),
                COALESCE(CAST(CASE WHEN json_extract(t.metadata, '$.manual_disc_number_set') = 1 THEN json_extract(t.metadata, '$.manual_disc_number') ELSE json_extract(t.metadata, '$.disc_number') END AS INTEGER), 0),
                COALESCE(CAST(CASE WHEN json_extract(t.metadata, '$.manual_track_number_set') = 1 THEN json_extract(t.metadata, '$.manual_track_number') ELSE json_extract(t.metadata, '$.track_number') END AS INTEGER), 0),
                t.hub_track_id",
            _ => "LOWER(COALESCE(CASE WHEN json_extract(t.metadata, '$.manual_title_set') = 1 THEN json_extract(t.metadata, '$.manual_title') ELSE json_extract(t.metadata, '$.title') END, '')),
                LOWER(COALESCE(CASE WHEN json_extract(t.metadata, '$.manual_artist_set') = 1 THEN json_extract(t.metadata, '$.manual_artist') ELSE json_extract(t.metadata, '$.artist') END, '')),
                t.hub_track_id",
        };
        let sql = format!(
            "SELECT t.hub_track_id, t.content_hash, t.metadata,\
             COALESCE((SELECT b.size FROM blobs b WHERE b.hash = t.content_hash),\
                      (SELECT rb.size FROM referenced_blobs rb WHERE rb.hash = t.content_hash AND rb.available = 1)),\
             EXISTS(SELECT 1 FROM blobs b WHERE b.hash = t.content_hash)\
             OR EXISTS(SELECT 1 FROM referenced_blobs rb WHERE rb.hash = t.content_hash AND rb.available = 1)\
             OR EXISTS(SELECT 1 FROM source_files sf WHERE sf.content_hash = t.content_hash AND sf.available = 1),\
             (SELECT l.payload FROM loudness l WHERE l.content_hash = t.content_hash \
              ORDER BY l.algorithm_version DESC LIMIT 1) \
             FROM tracks t WHERE t.purged_at IS NULL AND t.tombstoned_at IS NULL \
             {search} ORDER BY {order} LIMIT ?1 OFFSET ?2",
            search = if search.is_some() {
                "AND (t.metadata LIKE ?3 OR t.content_hash LIKE ?3)"
            } else {
                ""
            }
        );
        let mut statement = connection.prepare(&sql)?;
        let mut rows = if let Some(search) = search {
            statement.query(params![limit, cursor, search])?
        } else {
            statement.query(params![limit, cursor])?
        };
        let mut tracks = Vec::new();
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let metadata: Value = serde_json::from_str::<Value>(&row.get::<_, String>(2)?)
                .unwrap_or(Value::Object(Default::default()));
            let effective = |key: &str| {
                if metadata
                    .get(format!("manual_{key}_set"))
                    .and_then(Value::as_bool)
                    == Some(true)
                {
                    metadata.get(format!("manual_{key}"))
                } else {
                    metadata.get(key)
                }
            };
            let number = |key: &str| effective(key).and_then(Value::as_u64).map(|v| v as u32);
            let decimal = |key: &str| metadata.get(key).and_then(Value::as_f64);
            let text = |key: &str| effective(key).and_then(Value::as_str).map(str::to_owned);
            let original_artwork_hash = || {
                metadata
                    .get("artwork_hash")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| {
                        metadata
                            .get("artwork_url")
                            .and_then(Value::as_str)
                            .and_then(|url| {
                                url.strip_prefix("/v1/blobs/")
                                    .filter(|hash| !hash.is_empty())
                                    .map(str::to_owned)
                            })
                    })
            };
            let artwork_hash =
                if metadata.get("manual_artwork_set").and_then(Value::as_bool) == Some(true) {
                    metadata
                        .get("manual_artwork_hash")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                } else {
                    original_artwork_hash()
                };
            let loudness: Value = row
                .get::<_, Option<String>>(5)?
                .and_then(|payload| serde_json::from_str(&payload).ok())
                .unwrap_or_default();
            tracks.push(CatalogTrack {
                track_id: Uuid::parse_str(&id).unwrap_or_else(|_| Uuid::nil()),
                source_id: text("source_id").and_then(|value| Uuid::parse_str(&value).ok()),
                source_name: text("source_name"),
                content_hash: row.get(1)?,
                title: text("title").unwrap_or_else(|| "Unknown Track".to_owned()),
                artist: text("artist"),
                album: text("album"),
                genre: text("genre"),
                release_year: number("release_year"),
                duration_seconds: metadata.get("duration").and_then(Value::as_f64),
                byte_count: row.get(3)?,
                codec: text("codec"),
                sample_rate: decimal("sample_rate"),
                bit_depth: number("bit_depth"),
                channel_count: number("channel_count"),
                bitrate: decimal("bitrate"),
                integrated_lufs: loudness.get("integrated_lufs").and_then(Value::as_f64),
                peak_amplitude: loudness.get("peak_amplitude").and_then(Value::as_f64),
                loudness_analyzed_at: loudness.get("analyzed_at").and_then(Value::as_f64),
                loudness_algorithm_version: loudness
                    .get("algorithm_version")
                    .and_then(Value::as_u64)
                    .map(|value| value as u32),
                track_number: number("track_number"),
                disc_number: number("disc_number"),
                artwork_hash,
                favourite: metadata
                    .get("favourite")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                available: row.get(4)?,
            });
        }
        drop(rows);
        drop(statement);
        drop(connection);
        let next_cursor =
            (tracks.len() == limit as usize).then(|| (cursor + tracks.len() as u64).to_string());
        let revision = self.latest_sequence()?;
        Ok(CatalogPage {
            tracks,
            next_cursor,
            revision,
        })
    }

    pub fn export_manifest(&self, library_name: &str) -> Result<ExportManifest, StoreError> {
        let connection = self.connection.lock();
        let recovery_cutoff = chrono::Utc::now().timestamp() - 30 * 24 * 60 * 60;
        let mut statement = connection.prepare(
            r#"
            SELECT t.hub_track_id, t.content_hash, t.metadata, t.tombstoned_at,
                   COALESCE(b.size, rb.size)
            FROM tracks AS t
            LEFT JOIN blobs AS b ON b.hash = t.content_hash
            LEFT JOIN referenced_blobs AS rb ON rb.hash = t.content_hash
            WHERE t.purged_at IS NULL
              AND t.content_hash IS NOT NULL
              AND (t.tombstoned_at IS NULL OR t.tombstoned_at >= ?1)
            ORDER BY t.hub_track_id
            "#,
        )?;
        let rows = statement.query_map([recovery_cutoff], |row| {
            let track_id: String = row.get(0)?;
            let hash: String = row.get(1)?;
            let metadata_json: String = row.get(2)?;
            let metadata: serde_json::Map<String, Value> =
                serde_json::from_str(&metadata_json).unwrap_or_default();
            let effective = |key: &str| {
                if metadata
                    .get(&format!("manual_{key}_set"))
                    .and_then(Value::as_bool)
                    == Some(true)
                {
                    metadata.get(&format!("manual_{key}"))
                } else {
                    metadata.get(key)
                }
            };
            let text = |key: &str| effective(key).and_then(Value::as_str).map(str::to_owned);
            let integer = |key: &str| {
                effective(key)
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
            };
            let title = text("title").unwrap_or_else(|| "Unknown Track".into());
            let original_filename = text("original_filename").unwrap_or_else(|| {
                format!(
                    "{title}.{}",
                    text("original_extension").unwrap_or_else(|| "audio".into())
                )
            });
            Ok(ExportTrack {
                track_id: Uuid::parse_str(&track_id).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        track_id.len(),
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?,
                content_hash: hash,
                byte_count: row.get::<_, Option<u64>>(4)?.unwrap_or_else(|| {
                    metadata
                        .get("byte_count")
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                }),
                title,
                artist: text("artist").unwrap_or_else(|| "Unknown Artist".into()),
                album: text("album"),
                track_number: integer("track_number"),
                disc_number: integer("disc_number"),
                original_extension: text("original_extension").unwrap_or_else(|| {
                    Path::new(&original_filename)
                        .extension()
                        .and_then(|value| value.to_str())
                        .unwrap_or("audio")
                        .to_owned()
                }),
                original_filename,
                removed_at: row
                    .get::<_, Option<i64>>(3)?
                    .and_then(|timestamp| chrono::DateTime::from_timestamp(timestamp, 0)),
            })
        })?;
        Ok(ExportManifest {
            schema_version: 1,
            library_name: library_name.to_owned(),
            generated_at: chrono::Utc::now(),
            tracks: rows.collect::<Result<_, _>>()?,
        })
    }

    pub fn garbage_collect_expired_blobs(&self) -> Result<usize, StoreError> {
        let cutoff = chrono::Utc::now().timestamp() - 30 * 24 * 60 * 60;
        let hashes: Vec<String> = {
            let connection = self.connection.lock();
            let mut statement = connection.prepare(
                r#"
                SELECT DISTINCT content_hash
                FROM tracks
                WHERE tombstoned_at IS NOT NULL
                  AND tombstoned_at < ?1
                  AND purged_at IS NULL
                  AND content_hash IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM tracks AS live
                      WHERE live.content_hash = tracks.content_hash
                        AND live.tombstoned_at IS NULL
                        AND live.purged_at IS NULL
                  )
                "#,
            )?;
            statement
                .query_map([cutoff], |row| row.get(0))?
                .collect::<Result<_, _>>()?
        };
        let mut removed = 0;
        for hash in hashes {
            {
                let connection = self.connection.lock();
                connection.execute(
                    "UPDATE tracks SET purged_at = unixepoch() \
                     WHERE content_hash = ?1 AND tombstoned_at < ?2",
                    params![hash, cutoff],
                )?;
            }
            if self.purge_blob(&hash)? {
                removed += 1;
            }
        }
        Ok(removed)
    }

    pub fn create_join_preview(
        &self,
        request: &JoinPreviewRequest,
    ) -> Result<JoinPreview, StoreError> {
        let hub_tracks = self.all_snapshot_tracks()?;
        let hub_by_hash: std::collections::HashMap<&str, &ManifestEntry> = hub_tracks
            .iter()
            .filter_map(|track| track.content_hash.as_deref().map(|hash| (hash, track)))
            .collect();
        let mut matched_hub_ids = HashSet::new();
        let mut deduplicated_tracks = 0;
        let mut local_only_tracks = 0;
        let mut required_bytes = 0;
        let mut conflicts = Vec::new();

        for local in &request.manifest {
            let matching = local
                .content_hash
                .as_deref()
                .and_then(|hash| hub_by_hash.get(hash).copied());
            if let Some(hub) = matching {
                deduplicated_tracks += 1;
                if let Some(hub_track_id) = hub.hub_track_id {
                    matched_hub_ids.insert(hub_track_id);
                    for (field, local_value) in &local.fields {
                        if let Some(hub_value) = hub.fields.get(field)
                            && local_value.value != hub_value.value
                        {
                            conflicts.push(FieldConflict {
                                track_id: hub_track_id,
                                field: field.clone(),
                                local: local_value.clone(),
                                hub: hub_value.clone(),
                            });
                        }
                    }
                }
            } else {
                local_only_tracks += 1;
                required_bytes += local
                    .fields
                    .get("byte_count")
                    .and_then(|value| value.value.as_u64())
                    .unwrap_or(0);
            }
        }

        let preview = JoinPreview {
            preview_id: Uuid::new_v4(),
            deduplicated_tracks,
            local_only_tracks,
            hub_only_tracks: hub_tracks
                .iter()
                .filter(|track| {
                    track
                        .hub_track_id
                        .is_some_and(|id| !matched_hub_ids.contains(&id))
                })
                .count(),
            conflicts,
            required_bytes,
        };
        self.connection.lock().execute(
            r#"
            INSERT INTO join_previews
                (preview_id, device_id, request, preview, created_at, consumed_at)
            VALUES (?1, ?2, ?3, ?4, unixepoch(), NULL)
            "#,
            params![
                preview.preview_id.to_string(),
                request.device_id.to_string(),
                serde_json::to_string(request).expect("join request serialization"),
                serde_json::to_string(&preview).expect("join preview serialization"),
            ],
        )?;
        Ok(preview)
    }

    pub fn commit_join(
        &self,
        device_id: Uuid,
        request: &JoinCommitRequest,
    ) -> Result<Vec<SequencedOperation>, StoreError> {
        let (join_request, preview): (JoinPreviewRequest, JoinPreview) = {
            let connection = self.connection.lock();
            let row: Option<(String, String)> = connection
                .query_row(
                    r#"
                    SELECT request, preview
                    FROM join_previews
                    WHERE preview_id = ?1 AND device_id = ?2 AND consumed_at IS NULL
                    "#,
                    params![request.preview_id.to_string(), device_id.to_string()],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let Some((join_request, preview)) = row else {
                return Err(StoreError::JoinPreviewNotFound);
            };
            (
                serde_json::from_str(&join_request).expect("stored join request"),
                serde_json::from_str(&preview).expect("stored join preview"),
            )
        };

        for conflict in &preview.conflicts {
            let key = format!("{}:{}", conflict.track_id, conflict.field);
            if !request.resolutions.contains_key(&key) {
                return Err(StoreError::JoinPreviewNotFound);
            }
        }

        let claimed = self.connection.lock().execute(
            r#"
            UPDATE join_previews SET consumed_at = unixepoch()
            WHERE preview_id = ?1 AND device_id = ?2 AND consumed_at IS NULL
            "#,
            params![request.preview_id.to_string(), device_id.to_string()],
        )?;
        if claimed != 1 {
            return Err(StoreError::JoinPreviewNotFound);
        }

        let hub_tracks = self.all_snapshot_tracks()?;
        let hub_by_hash: std::collections::HashMap<&str, Uuid> = hub_tracks
            .iter()
            .filter_map(|track| Some((track.content_hash.as_deref()?, track.hub_track_id?)))
            .collect();
        let now = chrono::Utc::now().timestamp_millis();
        let operations: Vec<Operation> = join_request
            .manifest
            .into_iter()
            .enumerate()
            .map(|(index, local)| {
                let hub_track_id = local
                    .content_hash
                    .as_deref()
                    .and_then(|hash| hub_by_hash.get(hash).copied())
                    .or(local.hub_track_id)
                    .unwrap_or_else(Uuid::new_v4);
                let mut payload = serde_json::Map::new();
                let mut field_versions = BTreeMap::new();
                for (field, value) in local.fields {
                    let resolution_key = format!("{hub_track_id}:{field}");
                    if request.resolutions.get(&resolution_key) == Some(&ConflictChoice::Hub) {
                        continue;
                    }
                    payload.insert(field.clone(), value.value);
                    let timestamp = if request.resolutions.get(&resolution_key)
                        == Some(&ConflictChoice::Local)
                    {
                        HybridTimestamp {
                            physical_millis: now,
                            logical: index as u32,
                            device_id,
                        }
                    } else {
                        value.timestamp
                    };
                    field_versions.insert(field, timestamp);
                }
                if let Some(hash) = local.content_hash {
                    payload.insert("content_hash".into(), Value::String(hash));
                    field_versions
                        .entry("content_hash".into())
                        .or_insert(HybridTimestamp {
                            physical_millis: now,
                            logical: index as u32,
                            device_id,
                        });
                }
                Operation {
                    operation_id: Uuid::new_v4(),
                    device_id,
                    entity_type: "track".into(),
                    entity_id: hub_track_id.to_string(),
                    kind: if local.tombstoned {
                        "tombstone".into()
                    } else {
                        "upsert".into()
                    },
                    payload: Value::Object(payload),
                    field_versions,
                }
            })
            .collect();
        match self.append_operations(&operations) {
            Ok(accepted) => Ok(accepted),
            Err(error) => {
                let _ = self.connection.lock().execute(
                    "UPDATE join_previews SET consumed_at = NULL WHERE preview_id = ?1",
                    [request.preview_id.to_string()],
                );
                Err(error)
            }
        }
    }

    pub fn save_device(&self, summary: &DeviceSummary, credential: &str) -> Result<(), StoreError> {
        let hash = hex::encode(Sha256::digest(credential.as_bytes()));
        self.connection.lock().execute(
            r#"
            INSERT INTO device_credentials
                (device_id, name, device_type, credential_hash, paired_at,
                 revoked_at, can_contribute)
            VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6)
            ON CONFLICT(device_id) DO UPDATE SET
                name = excluded.name,
                device_type = excluded.device_type,
                credential_hash = excluded.credential_hash,
                paired_at = excluded.paired_at,
                revoked_at = NULL,
                can_contribute = excluded.can_contribute
            "#,
            params![
                summary.device_id.to_string(),
                summary.name,
                summary.device_type,
                hash,
                summary.paired_at.to_rfc3339(),
                summary.can_contribute,
            ],
        )?;
        Ok(())
    }

    pub fn authorize_device(&self, device_id: Uuid, credential: &str) -> Result<bool, StoreError> {
        let stored: Option<String> = self
            .connection
            .lock()
            .query_row(
                "SELECT credential_hash FROM device_credentials WHERE device_id = ?1 AND revoked_at IS NULL",
                [device_id.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        let Some(stored) = stored else {
            return Ok(false);
        };
        let candidate = hex::encode(Sha256::digest(credential.as_bytes()));
        Ok(stored.as_bytes().ct_eq(candidate.as_bytes()).into())
    }

    pub fn device_can_contribute(&self, device_id: Uuid) -> Result<bool, StoreError> {
        Ok(self
            .connection
            .lock()
            .query_row(
                "SELECT can_contribute FROM device_credentials \
                 WHERE device_id = ?1 AND revoked_at IS NULL",
                [device_id.to_string()],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(false))
    }

    pub fn library_accepts_contributions(&self) -> Result<bool, StoreError> {
        let connection = self.connection.lock();
        let source_count: i64 =
            connection.query_row("SELECT COUNT(*) FROM sources", [], |row| row.get(0))?;
        let stored_count: i64 = connection.query_row(
            "SELECT COUNT(*) FROM sources WHERE mode = 'managed'",
            [],
            |row| row.get(0),
        )?;
        Ok(source_count == 0 || stored_count > 0)
    }

    pub fn tombstone_by_hash(
        &self,
        content_hash: &str,
        device_id: Uuid,
    ) -> Result<bool, StoreError> {
        let track_id: Option<String> = self
            .connection
            .lock()
            .query_row(
                r#"
                SELECT hub_track_id
                FROM tracks
                WHERE content_hash = ?1 AND tombstoned_at IS NULL
                LIMIT 1
                "#,
                [content_hash],
                |row| row.get(0),
            )
            .optional()?;
        let Some(track_id) = track_id else {
            return Ok(false);
        };
        self.append_operations(&[Operation {
            operation_id: Uuid::new_v4(),
            device_id,
            entity_type: "track_state".into(),
            entity_id: track_id,
            kind: "delete".into(),
            payload: serde_json::json!({
                "deleted_at": chrono::Utc::now().timestamp_millis()
            }),
            field_versions: BTreeMap::new(),
        }])?;
        Ok(true)
    }

    pub fn set_device_contribution(
        &self,
        device_id: Uuid,
        can_contribute: bool,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.lock().execute(
            "UPDATE device_credentials SET can_contribute = ?1 \
             WHERE device_id = ?2 AND revoked_at IS NULL",
            params![can_contribute, device_id.to_string()],
        )? == 1)
    }

    pub fn devices(&self) -> Result<Vec<DeviceSummary>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT device_id, name, device_type, paired_at, revoked_at,
                   last_seen_at, last_synced_at, offline_track_count,
                   can_contribute
            FROM device_credentials ORDER BY paired_at
            "#,
        )?;
        let devices = statement.query_map([], |row| {
            let id: String = row.get(0)?;
            let paired_at: String = row.get(3)?;
            let revoked_at: Option<String> = row.get(4)?;
            Ok(DeviceSummary {
                device_id: Uuid::parse_str(&id).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        id.len(),
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?,
                name: row.get(1)?,
                device_type: row.get(2)?,
                paired_at: chrono::DateTime::parse_from_rfc3339(&paired_at)
                    .map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            paired_at.len(),
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?
                    .to_utc(),
                revoked_at: revoked_at
                    .map(|value| {
                        chrono::DateTime::parse_from_rfc3339(&value).map(|date| date.to_utc())
                    })
                    .transpose()
                    .map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?,
                last_seen_at: optional_timestamp(row.get(5)?)?,
                last_synced_at: optional_timestamp(row.get(6)?)?,
                offline_track_count: row.get(7)?,
                can_contribute: row.get(8)?,
            })
        })?;
        devices.collect::<Result<_, _>>().map_err(Into::into)
    }

    pub fn record_device_seen(
        &self,
        device_id: Uuid,
        synced: bool,
        offline_track_count: Option<u64>,
    ) -> Result<(), StoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        // Same signed-INTEGER constraint as `changes_after`: this count comes
        // straight off the wire, and a device reporting an absurd figure should
        // record a saturated count rather than fail the whole exchange.
        let offline_track_count = offline_track_count.map(|count| count.min(i64::MAX as u64));
        self.connection.lock().execute(
            r#"
            UPDATE device_credentials
            SET last_seen_at = ?1,
                last_synced_at = CASE WHEN ?2 THEN ?1 ELSE last_synced_at END,
                offline_track_count = COALESCE(?3, offline_track_count)
            WHERE device_id = ?4 AND revoked_at IS NULL
            "#,
            params![now, synced, offline_track_count, device_id.to_string()],
        )?;
        Ok(())
    }

    pub fn update_source_health(
        &self,
        device_id: Uuid,
        sources: &[SourceHealthReport],
    ) -> Result<(), StoreError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        for source in sources {
            transaction.execute(
                r#"
                INSERT INTO sources
                    (source_id, mode, path, available, warning,
                     owner_device_id, name, last_seen_at)
                VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(source_id) DO UPDATE SET
                    mode = excluded.mode,
                    available = excluded.available,
                    warning = excluded.warning,
                    owner_device_id = excluded.owner_device_id,
                    name = excluded.name,
                    last_seen_at = excluded.last_seen_at
                "#,
                params![
                    source.source_id.to_string(),
                    source.mode,
                    source.available,
                    source.warning,
                    device_id.to_string(),
                    source.name,
                    chrono::Utc::now().to_rfc3339(),
                ],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn refresh_host_source_health(&self) -> Result<(), StoreError> {
        let sources: Vec<(String, String, String)> = {
            let connection = self.connection.lock();
            let mut statement = connection.prepare(
                "SELECT source_id, path, mode FROM sources
                     WHERE path IS NOT NULL AND detached_at IS NULL",
            )?;
            statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
                .collect::<Result<_, _>>()?
        };
        let connection = self.connection.lock();
        for (source_id, path, mode) in sources {
            let available = Path::new(&path).is_dir();
            let warning = (!available).then_some(if mode == "managed" {
                "The original folder is unavailable. Aro’s stored copy remains available."
            } else {
                "This linked folder is unavailable. Its tracks cannot be served until the folder is online."
            });
            connection.execute(
                r#"
                UPDATE sources
                SET available = ?1, warning = ?2, last_seen_at = ?3
                WHERE source_id = ?4
                "#,
                params![
                    available,
                    warning,
                    chrono::Utc::now().to_rfc3339(),
                    source_id
                ],
            )?;
        }
        Ok(())
    }

    pub fn source_health(&self) -> Result<Vec<SourceHealthReport>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT s.source_id, s.name, s.mode, s.available, s.warning,
                   COUNT(sf.relative_path)
            FROM sources s
            LEFT JOIN source_files sf ON sf.source_id = s.source_id AND sf.available = 1
            GROUP BY s.source_id
            ORDER BY s.name, s.source_id
            "#,
        )?;
        Ok(statement
            .query_map([], |row| {
                let source_id: String = row.get(0)?;
                Ok(SourceHealthReport {
                    source_id: Uuid::parse_str(&source_id).unwrap_or_default(),
                    name: row.get(1)?,
                    mode: row.get(2)?,
                    available: row.get(3)?,
                    warning: row.get(4)?,
                    song_count: Some(row.get(5)?),
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub fn active_track_count(&self) -> Result<u64, StoreError> {
        Ok(self.connection.lock().query_row(
            "SELECT COUNT(*) FROM tracks WHERE tombstoned_at IS NULL AND purged_at IS NULL",
            [],
            |row| row.get(0),
        )?)
    }

    pub fn record_playback_activity(
        &self,
        device_id: Uuid,
        snapshot: &PlaybackActivitySnapshot,
        peer_address: Option<&str>,
    ) -> Result<bool, StoreError> {
        let Some(track_id) = self.track_id_for_hash(&snapshot.content_hash)? else {
            return Ok(false);
        };
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let current: Option<u64> = transaction
            .query_row(
                "SELECT revision FROM playback_activity_latest
                 WHERE session_id = ?1 AND device_id = ?2",
                params![snapshot.session_id.to_string(), device_id.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        if current.is_some_and(|revision| revision >= snapshot.revision) {
            return Ok(false);
        }
        let state = match snapshot.state {
            PlaybackActivityState::Playing => "playing",
            PlaybackActivityState::Buffering => "buffering",
            PlaybackActivityState::Stopped => "stopped",
        };
        let payload = serde_json::to_string(snapshot).expect("playback snapshot serialization");
        transaction.execute(
            r#"
            INSERT INTO playback_activity_events
                (session_id, revision, device_id, track_id, state, observed_at,
                 peer_address, payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
            params![
                snapshot.session_id.to_string(),
                snapshot.revision,
                device_id.to_string(),
                track_id.to_string(),
                state,
                snapshot.observed_at.timestamp_millis(),
                peer_address,
                payload,
            ],
        )?;
        transaction.execute(
            r#"
            INSERT INTO playback_activity_latest
                (session_id, device_id, track_id, revision, state, observed_at,
                 peer_address, payload)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(session_id, device_id) DO UPDATE SET
                track_id = excluded.track_id,
                revision = excluded.revision,
                state = excluded.state,
                observed_at = excluded.observed_at,
                peer_address = excluded.peer_address,
                payload = excluded.payload
            WHERE excluded.revision > playback_activity_latest.revision
            "#,
            params![
                snapshot.session_id.to_string(),
                device_id.to_string(),
                track_id.to_string(),
                snapshot.revision,
                state,
                snapshot.observed_at.timestamp_millis(),
                peer_address,
                payload,
            ],
        )?;
        // Activity snapshots power live "now playing" telemetry only. Canonical
        // listening history arrives through the client's durable
        // `listening_session` operation after playback ends; deriving another event
        // here would double-count every online play and lose offline sessions.
        transaction.commit()?;
        Ok(true)
    }

    /// Seed data for server-side auto-playlist generation (see `aro-server`'s `playlists`
    /// module): every live content-addressed track with its favourite flag, mood tags,
    /// and first-seen time, plus decayed-affinity/skip/time-of-day aggregates from
    /// `listening_events` — all keyed by content hash, since that's the only identifier
    /// client libraries share with this database.
    pub fn playlist_seeds(&self) -> Result<PlaylistSeeds, StoreError> {
        let connection = self.connection.lock();
        let mut seeds = PlaylistSeeds::default();

        // Loaded up front (rather than a per-track lookup) so the tracks loop below
        // stays a single pass; `audio_features` is typically much smaller than
        // `tracks` (analysis is best-effort background work), so this is cheap.
        let mut audio_features_by_hash: HashMap<String, String> = HashMap::new();
        {
            let mut audio_feature_rows =
                connection.prepare("SELECT content_hash, payload FROM audio_features")?;
            let rows = audio_feature_rows.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            for row in rows {
                let (hash, payload) = row?;
                audio_features_by_hash.insert(hash, payload);
            }
        }

        let mut tracks = connection.prepare(
            r#"
            SELECT t.content_hash, t.metadata, t.field_versions, ir.mood_tags,
                   ir.musicbrainz_genres
            FROM tracks t
            LEFT JOIN identification_results ir ON ir.content_hash = t.content_hash
            WHERE t.content_hash IS NOT NULL
              AND t.tombstoned_at IS NULL
              AND t.purged_at IS NULL
            ORDER BY t.hub_track_id
            "#,
        )?;
        let track_rows = tracks.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })?;
        for row in track_rows {
            let (content_hash, metadata, field_versions, mood_tags, genres) = row?;
            let metadata: serde_json::Map<String, Value> =
                serde_json::from_str(&metadata).unwrap_or_default();
            let favourite = metadata
                .get("favourite")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let mood_tags: Vec<String> = mood_tags
                .and_then(|json| serde_json::from_str(&json).ok())
                .unwrap_or_default();
            let genres: Vec<String> = genres
                .and_then(|json| serde_json::from_str::<Vec<String>>(&json).ok())
                .unwrap_or_default()
                .into_iter()
                .map(|genre| genre.trim().to_lowercase())
                .filter(|genre| !genre.is_empty())
                .collect();
            // A freshly scanned track writes every field at (approximately) the same
            // instant, so the earliest per-field timestamp is a good proxy for "when
            // this track was added" without needing a dedicated column.
            let versions: serde_json::Map<String, Value> =
                serde_json::from_str(&field_versions).unwrap_or_default();
            let first_seen_at_millis = versions
                .values()
                .filter_map(|value| value.get("physical_millis").and_then(Value::as_i64))
                .min();
            let text = |key: &str| {
                metadata
                    .get(key)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
            };
            let audio_features_json = audio_features_by_hash.get(&content_hash).cloned();
            seeds.tracks.push(PlaylistSeedTrack {
                content_hash,
                favourite,
                mood_tags,
                genres,
                first_seen_at_millis,
                artist: text("artist"),
                album: text("album"),
                release_year: metadata.get("release_year").and_then(Value::as_i64),
                audio_features_json,
            });
        }
        drop(tracks);

        const DECAY_HALF_LIFE_DAYS: f64 = 45.0;
        let now_utc = chrono::Utc::now();
        let now = now_utc.timestamp() as f64;
        let current_month = {
            use chrono::Datelike;
            (now_utc.year(), now_utc.month())
        };

        let mut listening = connection.prepare(
            r#"
            SELECT t.content_hash, l.started_at, l.skipped, l.completed
            FROM listening_events l
            JOIN tracks t ON t.hub_track_id = l.track_id
            WHERE t.content_hash IS NOT NULL AND l.started_at IS NOT NULL
            "#,
        )?;
        let listening_rows = listening.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, bool>(3)?,
            ))
        })?;
        for row in listening_rows {
            let (content_hash, started_at, skipped, completed) = row?;
            let summary = seeds.listening.entry(content_hash).or_default();
            summary.play_count += 1;
            if skipped {
                summary.skip_count += 1;
            }
            if completed {
                summary.completed_count += 1;
            }
            summary.last_played_at = summary.last_played_at.max(started_at);
            let age_days = ((now - started_at) / 86_400.0).max(0.0);
            summary.decayed_affinity += 0.5_f64.powf(age_days / DECAY_HALF_LIFE_DAYS);
            if let Some(played_at) = chrono::DateTime::from_timestamp(started_at as i64, 0) {
                use chrono::{Datelike, Timelike};
                let bucket = played_at.hour() as usize;
                if bucket < 24 {
                    summary.hour_histogram[bucket] += 1;
                }
                if played_at.year() == current_month.0 && played_at.month() == current_month.1 {
                    summary.current_month_play_count += 1;
                }
                let year = played_at.year();
                summary.first_played_year = Some(
                    summary
                        .first_played_year
                        .map_or(year, |existing| existing.min(year)),
                );
                summary.last_played_year = Some(
                    summary
                        .last_played_year
                        .map_or(year, |existing| existing.max(year)),
                );
            }
        }
        drop(listening);

        // Heartbeats are collapsed to one row per playback session first — they arrive
        // every few seconds, so counting them directly would rank long tracks and stalled
        // buffering above anything actually enjoyed.
        let mut engagement = connection.prepare(
            r#"
            SELECT content_hash,
                   COUNT(*),
                   SUM(CASE WHEN completed OR fraction >= 0.9 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN NOT completed AND fraction < 0.5 THEN 1 ELSE 0 END),
                   AVG(fraction),
                   MAX(observed_at)
            FROM (
                SELECT content_hash,
                       MIN(1.0, position / duration) AS fraction,
                       completed,
                       observed_at
                FROM (
                    SELECT json_extract(payload, '$.content_hash') AS content_hash,
                           MAX(COALESCE(json_extract(payload, '$.position_seconds'), 0)) AS position,
                           MAX(COALESCE(json_extract(payload, '$.duration_seconds'), 0)) AS duration,
                           MAX(COALESCE(json_extract(payload, '$.completed'), 0)) AS completed,
                           MAX(observed_at) / 1000.0 AS observed_at
                    FROM playback_activity_events
                    GROUP BY session_id
                )
                WHERE content_hash IS NOT NULL AND duration > 0
            )
            GROUP BY content_hash
            "#,
        )?;
        let mut rows = engagement.query([])?;
        while let Some(row) = rows.next()? {
            let content_hash: String = row.get(0)?;
            seeds.engagement.insert(
                content_hash,
                EngagementSummary {
                    sessions: row.get(1)?,
                    completed_sessions: row.get(2)?,
                    abandoned_sessions: row.get(3)?,
                    mean_fraction: row.get::<_, Option<f64>>(4)?.unwrap_or(0.0),
                    last_observed_at: row.get::<_, Option<f64>>(5)?.unwrap_or(0.0),
                },
            );
        }
        drop(rows);
        drop(engagement);

        Ok(seeds)
    }

    pub fn dashboard_stats(&self) -> Result<Value, StoreError> {
        let connection = self.connection.lock();
        let mut tracks = connection.prepare(
            r#"
            SELECT t.metadata, COALESCE(b.size, rb.size, 0)
            FROM tracks t
            LEFT JOIN blobs b ON b.hash = t.content_hash
            LEFT JOIN referenced_blobs rb
                ON rb.hash = t.content_hash AND rb.available = 1
            WHERE t.tombstoned_at IS NULL AND t.purged_at IS NULL
            "#,
        )?;
        let rows = tracks.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, u64>(1)?))
        })?;
        let mut track_count = 0_u64;
        let mut total_duration = 0_f64;
        let mut file_size_bytes = 0_u64;
        let mut artists = HashSet::new();
        let mut albums = HashSet::new();
        let mut formats: HashMap<String, (u64, u64)> = HashMap::new();
        let mut genres: HashMap<String, (u64, u64)> = HashMap::new();
        let mut decades: HashMap<String, (u64, u64)> = HashMap::new();
        let mut sample_rates: HashMap<String, u64> = HashMap::new();
        let mut bit_depths: HashMap<String, u64> = HashMap::new();
        let mut complete_title = 0_u64;
        let mut complete_artist = 0_u64;
        let mut complete_album = 0_u64;
        // Lossless is a property of the codec, not the bit depth: a 16-bit ALAC file is
        // lossless while a 16-bit-decoded MP3 is not, and both report a bit depth.
        let mut lossless_tracks = 0_u64;
        let mut lossless_bytes = 0_u64;
        let mut lossy_bitrate_total = 0_f64;
        let mut lossy_bitrate_count = 0_u64;
        let mut high_resolution_tracks = 0_u64;
        for row in rows {
            let (metadata, size) = row?;
            let metadata: serde_json::Map<String, Value> =
                serde_json::from_str(&metadata).unwrap_or_default();
            track_count += 1;
            file_size_bytes = file_size_bytes.saturating_add(size);
            total_duration += metadata
                .get("duration")
                .and_then(Value::as_f64)
                .unwrap_or_default();
            let text = |key: &str| {
                metadata
                    .get(key)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
            };
            if text("title").is_some() {
                complete_title += 1;
            }
            if let Some(artist) = text("artist") {
                complete_artist += 1;
                artists.insert(artist.to_owned());
            }
            if let Some(album) = text("album") {
                complete_album += 1;
                albums.insert(album.to_owned());
            }
            let format = text("codec").unwrap_or("unknown").to_ascii_uppercase();
            let entry = formats.entry(format).or_default();
            entry.0 += 1;
            entry.1 = entry.1.saturating_add(size);
            let genre = text("genre").unwrap_or("Unknown").to_owned();
            let entry = genres.entry(genre).or_default();
            entry.0 += 1;
            entry.1 = entry.1.saturating_add(size);
            let decade = metadata
                .get("release_year")
                .and_then(Value::as_i64)
                .map(|year| format!("{}s", year / 10 * 10))
                .unwrap_or_else(|| "Unknown".into());
            let entry = decades.entry(decade).or_default();
            entry.0 += 1;
            entry.1 = entry.1.saturating_add(size);
            if let Some(rate) = metadata.get("sample_rate").and_then(Value::as_u64) {
                *sample_rates.entry(rate.to_string()).or_default() += 1;
            }
            if let Some(depth) = metadata.get("bit_depth").and_then(Value::as_u64) {
                *bit_depths.entry(depth.to_string()).or_default() += 1;
            }
            let codec = text("codec").unwrap_or_default().to_ascii_lowercase();
            if is_lossless(&codec, &metadata) {
                lossless_tracks += 1;
                lossless_bytes = lossless_bytes.saturating_add(size);
                // Anything beyond CD — 24-bit, or faster than 48 kHz — is what a listener
                // means by "high resolution".
                let depth = metadata
                    .get("bit_depth")
                    .and_then(Value::as_u64)
                    .unwrap_or(16);
                let rate = metadata
                    .get("sample_rate")
                    .and_then(Value::as_f64)
                    .unwrap_or(44_100.0);
                if depth > 16 || rate > 48_000.0 {
                    high_resolution_tracks += 1;
                }
            } else if let Some(bitrate) = metadata.get("bitrate").and_then(Value::as_f64) {
                lossy_bitrate_total += bitrate;
                lossy_bitrate_count += 1;
            }
        }
        drop(tracks);

        // Crest factor, already measured for every analyzed track. For a losslessly-ripped
        // library this is the statistic that actually separates pressings: two copies of
        // one album can differ by more here than by any other measure available.
        let dynamic_range = connection
            .query_row(
                r#"
                SELECT AVG(crest), MIN(crest), MAX(crest), COUNT(*)
                FROM (
                    SELECT json_extract(payload, '$.dynamic_range') AS crest
                    FROM audio_features
                )
                WHERE crest IS NOT NULL
                "#,
                [],
                |row| {
                    Ok(serde_json::json!({
                        "mean_crest_db": row.get::<_, Option<f64>>(0)?,
                        "min_crest_db": row.get::<_, Option<f64>>(1)?,
                        "max_crest_db": row.get::<_, Option<f64>>(2)?,
                        "analyzed_tracks": row.get::<_, i64>(3)?,
                    }))
                },
            )
            .optional()?
            .unwrap_or(Value::Null);

        let mut listening = connection.query_row(
            r#"
            SELECT COALESCE(SUM(listened_seconds), 0),
                   COALESCE(SUM(CASE WHEN started_at >= unixepoch() - 2592000
                                    THEN listened_seconds ELSE 0 END), 0),
                   COUNT(*), COUNT(DISTINCT track_id)
            FROM listening_events
            "#,
            [],
            |row| {
                Ok(serde_json::json!({
                    "total_seconds": row.get::<_, f64>(0)?,
                    "last_30_days_seconds": row.get::<_, f64>(1)?,
                    "logged_plays": row.get::<_, u64>(2)?,
                    "unique_tracks_played": row.get::<_, u64>(3)?,
                }))
            },
        )?;
        let today = chrono::Utc::now().date_naive();
        let first_day = today - chrono::Days::new(29);
        let mut seconds_by_day: BTreeMap<chrono::NaiveDate, f64> = BTreeMap::new();
        let mut top_tracks: HashMap<String, (String, String, u64)> = HashMap::new();
        let mut top_artists: HashMap<String, (HashSet<String>, u64)> = HashMap::new();
        let mut recent = Vec::new();
        let mut history = connection.prepare(
            r#"
            SELECT l.event_id, l.track_id, l.started_at, l.listened_seconds,
                   COALESCE(t.metadata, '{}')
            FROM listening_events l
            LEFT JOIN tracks t ON t.hub_track_id = l.track_id
            ORDER BY l.started_at DESC
            "#,
        )?;
        let history_rows = history.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<f64>>(2)?,
                row.get::<_, f64>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?;
        for row in history_rows {
            let (event_id, track_id, started_at, listened_seconds, metadata) = row?;
            let metadata: Value = serde_json::from_str(&metadata).unwrap_or_default();
            let title = metadata["title"].as_str().unwrap_or("Unknown Track");
            let artist = metadata["artist"].as_str().unwrap_or("Unknown Artist");
            let album = metadata["album"].as_str().unwrap_or("Unknown Album");
            if let Some(started_at) = started_at
                && let Some(date) = chrono::DateTime::from_timestamp(
                    started_at as i64,
                    ((started_at.fract() * 1_000_000_000.0) as u32).min(999_999_999),
                )
            {
                *seconds_by_day.entry(date.date_naive()).or_default() += listened_seconds;
                if recent.len() < 8 {
                    recent.push(serde_json::json!({
                        "id": event_id,
                        "title": title,
                        "subtitle": format!("{artist} — {album}"),
                        "played_at": date,
                    }));
                }
            }
            let entry = top_tracks
                .entry(track_id.clone())
                .or_insert_with(|| (title.to_owned(), format!("{artist} — {album}"), 0));
            entry.2 += 1;
            let entry = top_artists
                .entry(artist.to_owned())
                .or_insert_with(|| (HashSet::new(), 0));
            entry.0.insert(track_id);
            entry.1 += 1;
        }
        drop(history);
        let mut ranked_tracks = top_tracks
            .into_iter()
            .map(|(id, (title, subtitle, play_count))| {
                serde_json::json!({
                    "id": id, "title": title, "subtitle": subtitle,
                    "play_count": play_count
                })
            })
            .collect::<Vec<_>>();
        ranked_tracks.sort_by_key(|value| std::cmp::Reverse(value["play_count"].as_u64()));
        ranked_tracks.truncate(5);
        let mut ranked_artists = top_artists
            .into_iter()
            .map(|(artist, (tracks, play_count))| {
                serde_json::json!({
                    "id": artist, "title": artist,
                    "subtitle": format!("{} songs", tracks.len()),
                    "play_count": play_count
                })
            })
            .collect::<Vec<_>>();
        ranked_artists.sort_by_key(|value| std::cmp::Reverse(value["play_count"].as_u64()));
        ranked_artists.truncate(5);
        let daily = (0..30)
            .map(|offset| {
                let day = first_day + chrono::Days::new(offset);
                serde_json::json!({
                    "date": format!("{day}T00:00:00Z"),
                    "seconds": seconds_by_day.get(&day).copied().unwrap_or_default(),
                })
            })
            .collect::<Vec<_>>();
        let mut cursor = if seconds_by_day.contains_key(&today) {
            today
        } else {
            today - chrono::Days::new(1)
        };
        let mut streak = 0_u64;
        while seconds_by_day
            .get(&cursor)
            .is_some_and(|seconds| *seconds > 0.0)
        {
            streak += 1;
            cursor = cursor - chrono::Days::new(1);
        }
        listening["current_streak"] = serde_json::json!(streak);
        listening["daily"] = serde_json::json!(daily);
        listening["top_tracks"] = serde_json::json!(ranked_tracks);
        listening["top_artists"] = serde_json::json!(ranked_artists);
        listening["recent"] = serde_json::json!(recent);
        let active_cutoff = chrono::Utc::now().timestamp_millis() - 15_000;
        let active: u64 = connection.query_row(
            "SELECT COUNT(*) FROM playback_activity_latest
             WHERE state IN ('playing', 'buffering') AND observed_at >= ?1",
            [active_cutoff],
            |row| row.get(0),
        )?;
        let connected_cutoff = (chrono::Utc::now() - chrono::Duration::seconds(60)).to_rfc3339();
        let connected: u64 = connection.query_row(
            "SELECT COUNT(*) FROM device_credentials
             WHERE revoked_at IS NULL AND last_seen_at >= ?1",
            [connected_cutoff],
            |row| row.get(0),
        )?;
        let source_count: u64 = connection.query_row(
            "SELECT COUNT(*) FROM sources WHERE detached_at IS NULL",
            [],
            |r| r.get(0),
        )?;
        let unavailable_sources: u64 = connection.query_row(
            "SELECT COUNT(*) FROM sources
             WHERE detached_at IS NULL AND available = 0",
            [],
            |row| row.get(0),
        )?;
        let breakdown = |values: HashMap<String, (u64, u64)>| {
            let mut values = values
                .into_iter()
                .map(|(name, (track_count, file_size_bytes))| {
                    serde_json::json!({
                        "name": name,
                        "track_count": track_count,
                        "file_size_bytes": file_size_bytes,
                    })
                })
                .collect::<Vec<_>>();
            values.sort_by_key(|value| std::cmp::Reverse(value["track_count"].as_u64()));
            values
        };
        Ok(serde_json::json!({
            "generated_at": chrono::Utc::now(),
            "scope": "authoritative_hub",
            "live": {
                "active_listeners": active,
                "connected_devices": connected,
            },
            "listening": listening,
            "library": {
                "track_count": track_count,
                "album_count": albums.len(),
                "artist_count": artists.len(),
                "total_duration": total_duration,
                "file_size_bytes": file_size_bytes,
                "formats": breakdown(formats),
                "genres": breakdown(genres),
                "decades": breakdown(decades),
                "sample_rates": sample_rates,
                "bit_depths": bit_depths,
            },
            // What an audiophile actually wants to know about their own library, from data
            // already collected: how much of it survived intact, how much is better than
            // CD, and which files are the weak links worth re-ripping.
            "fidelity": {
                "lossless_tracks": lossless_tracks,
                "lossless_fraction": ratio(lossless_tracks, track_count),
                "lossless_bytes": lossless_bytes,
                "lossy_tracks": track_count.saturating_sub(lossless_tracks),
                "high_resolution_tracks": high_resolution_tracks,
                "mean_lossy_bitrate": if lossy_bitrate_count == 0 {
                    Value::Null
                } else {
                    Value::from(lossy_bitrate_total / lossy_bitrate_count as f64)
                },
                "dynamic_range": dynamic_range,
            },
            "metadata": {
                "title_coverage": ratio(complete_title, track_count),
                "artist_coverage": ratio(complete_artist, track_count),
                "album_coverage": ratio(complete_album, track_count),
            },
            "sources": {
                "total": source_count,
                "unavailable": unavailable_sources,
            }
        }))
    }

    pub fn dashboard_live_activity(&self) -> Result<Vec<Value>, StoreError> {
        let connection = self.connection.lock();
        let cutoff = chrono::Utc::now().timestamp_millis() - 15_000;
        let mut statement = connection.prepare(
            r#"
            SELECT p.session_id, p.device_id, COALESCE(d.name, 'Local Host'),
                   COALESCE(d.device_type, 'Mac'), p.state, p.observed_at,
                   p.peer_address, p.payload, t.metadata
            FROM playback_activity_latest p
            LEFT JOIN device_credentials d ON d.device_id = p.device_id
            LEFT JOIN tracks t ON t.hub_track_id = p.track_id
            WHERE p.state IN ('playing', 'buffering') AND p.observed_at >= ?1
            ORDER BY p.observed_at DESC
            "#,
        )?;
        let rows = statement.query_map([cutoff], |row| {
            let payload: String = row.get(7)?;
            let metadata: String = row.get(8)?;
            Ok(serde_json::json!({
                "session_id": row.get::<_, String>(0)?,
                "device_id": row.get::<_, String>(1)?,
                "device_name": row.get::<_, String>(2)?,
                "device_type": row.get::<_, String>(3)?,
                "state": row.get::<_, String>(4)?,
                "observed_at_millis": row.get::<_, i64>(5)?,
                "peer_address": row.get::<_, Option<String>>(6)?,
                "playback": serde_json::from_str::<Value>(&payload).unwrap_or_default(),
                "track": serde_json::from_str::<Value>(&metadata).unwrap_or_default(),
            }))
        })?;
        rows.collect::<Result<_, _>>().map_err(Into::into)
    }

    /// Active reports for the authenticated topology map. These are deliberately
    /// short-lived: a client that stops heartbeating is no longer presented as
    /// playing after 15 seconds.
    pub fn topology_live_activity(&self) -> Result<Vec<TopologyPlaybackActivity>, StoreError> {
        let connection = self.connection.lock();
        let cutoff = chrono::Utc::now().timestamp_millis() - 15_000;
        let mut statement = connection.prepare(
            r#"
            SELECT p.device_id, COALESCE(d.name, 'Local Host'),
                   COALESCE(d.device_type, 'Mac'), p.observed_at, p.payload
            FROM playback_activity_latest p
            LEFT JOIN device_credentials d ON d.device_id = p.device_id
            WHERE p.state IN ('playing', 'buffering') AND p.observed_at >= ?1
            ORDER BY p.observed_at DESC
            "#,
        )?;
        let rows = statement.query_map([cutoff], |row| {
            let payload: String = row.get(4)?;
            let playback =
                serde_json::from_str::<PlaybackActivitySnapshot>(&payload).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        4,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?;
            Ok(TopologyPlaybackActivity {
                device_id: Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?,
                device_name: row.get(1)?,
                device_type: row.get(2)?,
                state: playback.state,
                observed_at: chrono::DateTime::from_timestamp_millis(row.get(3)?)
                    .unwrap_or_else(chrono::Utc::now),
                playback,
            })
        })?;
        rows.collect::<Result<_, _>>().map_err(Into::into)
    }

    pub fn record_http_request(
        &self,
        method: &str,
        path: &str,
        peer_address: &str,
        status: u16,
        latency_micros: u64,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO http_request_events
                (observed_at, method, path, peer_address, status, latency_micros)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                chrono::Utc::now().timestamp_millis(),
                method,
                path,
                peer_address,
                status,
                latency_micros
            ],
        )?;
        Ok(())
    }

    pub fn dashboard_traffic(&self) -> Result<Value, StoreError> {
        let connection = self.connection.lock();
        let (total, errors, last_day, average_latency): (u64, u64, u64, f64) = connection
            .query_row(
                r#"
                SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN status >= 400 THEN 1 ELSE 0 END), 0),
                       COALESCE(SUM(CASE WHEN observed_at >=
                           (unixepoch() - 86400) * 1000 THEN 1 ELSE 0 END), 0),
                       COALESCE(AVG(latency_micros), 0)
                FROM http_request_events
                "#,
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )?;
        Ok(serde_json::json!({
            "generated_at": chrono::Utc::now(),
            "requests_total": total,
            "errors_total": errors,
            "requests_last_24_hours": last_day,
            "average_latency_milliseconds": average_latency / 1_000.0,
        }))
    }

    pub fn register_host_source(
        &self,
        source_id: Uuid,
        name: &str,
        mode: &str,
        path: &Path,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO sources
                (source_id, mode, path, available, warning, name, last_seen_at)
            VALUES (?1, ?2, ?3, 1, NULL, ?4, ?5)
            ON CONFLICT(source_id) DO UPDATE SET
                mode = excluded.mode,
                path = excluded.path,
                available = 1,
                warning = NULL,
                name = excluded.name,
                detached_at = NULL,
                last_seen_at = excluded.last_seen_at
            "#,
            params![
                source_id.to_string(),
                mode,
                path.to_string_lossy(),
                name,
                chrono::Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn revoke_device(&self, device_id: Uuid) -> Result<bool, StoreError> {
        Ok(self.connection.lock().execute(
            "UPDATE device_credentials SET revoked_at = ?1 WHERE device_id = ?2 AND revoked_at IS NULL",
            params![chrono::Utc::now().to_rfc3339(), device_id.to_string()],
        )? == 1)
    }

    pub fn blob_status(&self, hash: &str) -> Result<(bool, u64, u64), StoreError> {
        validate_hash(hash)?;
        let final_path = self.blob_path(hash);
        let upload_path = self.upload_path(hash);
        let referenced = self.referenced_blob_path(hash)?;
        let committed = final_path
            .metadata()
            .map(|metadata| metadata.len())
            .unwrap_or_else(|_| {
                referenced
                    .as_ref()
                    .and_then(|path| path.metadata().ok())
                    .map(|metadata| metadata.len())
                    .unwrap_or(0)
            });
        let uploaded = upload_path.metadata().map(|m| m.len()).unwrap_or(0);
        Ok((
            final_path.is_file() || referenced.is_some(),
            committed,
            uploaded,
        ))
    }

    pub fn import_managed(&self, source: &Path) -> Result<(String, u64), StoreError> {
        let (hash, size) = hash_file(source)?;
        if self.blob_path(&hash).is_file() {
            return Ok((hash, size));
        }
        let upload = self.upload_path(&hash);
        if upload.exists() {
            fs::remove_file(&upload)?;
        }
        fs::copy(source, &upload)?;
        self.commit_blob(&hash, size)?;
        Ok((hash, size))
    }

    pub fn source_folders(&self) -> Result<Vec<SourceFolder>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT s.source_id, s.name, s.path, s.available,
                   s.detached_at IS NULL, s.last_scan_at, s.last_error,
                   COUNT(sf.relative_path),
                   COALESCE(SUM(CASE WHEN sf.available = 0 THEN 1 ELSE 0 END), 0)
            FROM sources s
            LEFT JOIN source_files sf ON sf.source_id = s.source_id
            WHERE s.path IS NOT NULL
            GROUP BY s.source_id
            ORDER BY s.name, s.path
            "#,
        )?;
        Ok(statement
            .query_map([], |row| {
                let id: String = row.get(0)?;
                Ok(SourceFolder {
                    source_id: Uuid::parse_str(&id).unwrap_or_default(),
                    name: row.get(1)?,
                    path: PathBuf::from(row.get::<_, String>(2)?),
                    available: row.get(3)?,
                    watching: row.get(4)?,
                    last_scan_at: row.get(5)?,
                    last_error: row.get(6)?,
                    song_count: row.get(7)?,
                    missing_count: row.get(8)?,
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub fn source_folder(&self, source_id: Uuid) -> Result<Option<SourceFolder>, StoreError> {
        Ok(self
            .source_folders()?
            .into_iter()
            .find(|source| source.source_id == source_id))
    }

    pub fn source_files(&self, source_id: Uuid) -> Result<Vec<SourceFile>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT relative_path, hub_track_id, content_hash, size,
                   modified_millis, available
            FROM source_files WHERE source_id = ?1
            ORDER BY relative_path
            "#,
        )?;
        Ok(statement
            .query_map([source_id.to_string()], |row| {
                let track: String = row.get(1)?;
                Ok(SourceFile {
                    relative_path: row.get(0)?,
                    track_id: Uuid::parse_str(&track).unwrap_or_default(),
                    content_hash: row.get(2)?,
                    size: row.get(3)?,
                    modified_millis: row.get(4)?,
                    available: row.get(5)?,
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub fn track_id_for_hash(&self, hash: &str) -> Result<Option<Uuid>, StoreError> {
        let value: Option<String> = self
            .connection
            .lock()
            .query_row(
                "SELECT hub_track_id FROM tracks WHERE content_hash = ?1 AND purged_at IS NULL LIMIT 1",
                [hash],
                |row| row.get(0),
            )
            .optional()?;
        Ok(value.and_then(|value| Uuid::parse_str(&value).ok()))
    }

    pub fn upsert_source_file(
        &self,
        source_id: Uuid,
        relative_path: &str,
        track_id: Uuid,
        hash: &str,
        size: u64,
        modified_millis: i64,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO source_files
                (source_id, relative_path, hub_track_id, content_hash, size,
                 modified_millis, available, last_seen_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7)
            ON CONFLICT(source_id, relative_path) DO UPDATE SET
                hub_track_id = excluded.hub_track_id,
                content_hash = excluded.content_hash,
                size = excluded.size,
                modified_millis = excluded.modified_millis,
                available = 1,
                last_seen_at = excluded.last_seen_at
            "#,
            params![
                source_id.to_string(),
                relative_path,
                track_id.to_string(),
                hash,
                size,
                modified_millis,
                chrono::Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn finish_source_scan(
        &self,
        source_id: Uuid,
        seen_paths: &HashSet<String>,
        error: Option<&str>,
    ) -> Result<(), StoreError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        transaction.execute(
            "UPDATE source_files SET available = 0 WHERE source_id = ?1",
            [source_id.to_string()],
        )?;
        for path in seen_paths {
            transaction.execute(
                "UPDATE source_files SET available = 1 WHERE source_id = ?1 AND relative_path = ?2",
                params![source_id.to_string(), path],
            )?;
        }
        // A scan is the only thing that actually looks at the disk, so its verdict is the
        // freshest available. Without this, `referenced_blobs.available` was only ever
        // cleared lazily by a failed download and only ever restored by a re-import — so a
        // file that failed one verify for a transient reason (an unmounted volume, a
        // permissions blip) stayed marked unavailable until its size or mtime happened to
        // change, even while sitting right there on disk.
        transaction.execute(
            r#"
            UPDATE referenced_blobs SET available = 1
            WHERE hash IN (
                SELECT content_hash FROM source_files
                WHERE source_id = ?1 AND available = 1
            )
            "#,
            [source_id.to_string()],
        )?;
        transaction.execute(
            r#"
            UPDATE referenced_blobs SET available = 0
            WHERE hash IN (
                SELECT content_hash FROM source_files
                WHERE source_id = ?1 AND available = 0
            )
            AND hash NOT IN (
                -- Still reachable through another folder: one source losing a file says
                -- nothing about a copy that lives somewhere else.
                SELECT content_hash FROM source_files WHERE available = 1
            )
            "#,
            [source_id.to_string()],
        )?;
        transaction.execute(
            r#"
            UPDATE sources SET available = ?1, warning = ?2, last_error = ?2,
                last_scan_at = ?3, last_seen_at = ?3
            WHERE source_id = ?4
            "#,
            params![
                error.is_none(),
                error,
                chrono::Utc::now().to_rfc3339(),
                source_id.to_string(),
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn detach_source(&self, source_id: Uuid) -> Result<bool, StoreError> {
        Ok(self.connection.lock().execute(
            "UPDATE sources SET detached_at = ?1 WHERE source_id = ?2 AND detached_at IS NULL",
            params![chrono::Utc::now().to_rfc3339(), source_id.to_string()],
        )? == 1)
    }

    pub fn checkpoint(&self) -> Result<(), StoreError> {
        self.connection
            .lock()
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        Ok(())
    }

    pub fn import_referenced(&self, source: &Path) -> Result<(String, u64), StoreError> {
        let canonical = source.canonicalize()?;
        let (hash, size) = hash_file(&canonical)?;
        self.connection.lock().execute(
            r#"
            INSERT INTO referenced_blobs(hash, path, size, available, verified_at)
            VALUES (?1, ?2, ?3, 1, unixepoch())
            ON CONFLICT(hash) DO UPDATE SET
                path = excluded.path,
                size = excluded.size,
                available = 1,
                verified_at = excluded.verified_at
            "#,
            params![hash, canonical.to_string_lossy(), size],
        )?;
        Ok((hash, size))
    }

    pub fn write_chunk(&self, hash: &str, offset: u64, bytes: &[u8]) -> Result<u64, StoreError> {
        validate_hash(hash)?;
        if self.blob_path(hash).is_file() {
            return Ok(self.blob_path(hash).metadata()?.len());
        }
        let path = self.upload_path(hash);
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        let expected = file.metadata()?.len();
        if offset != expected {
            return Err(StoreError::OffsetMismatch {
                expected,
                received: offset,
            });
        }
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(bytes)?;
        file.sync_data()?;
        Ok(offset + bytes.len() as u64)
    }

    pub fn commit_blob(&self, hash: &str, expected_size: u64) -> Result<u64, StoreError> {
        validate_hash(hash)?;
        let final_path = self.blob_path(hash);
        if final_path.is_file() {
            let size = final_path.metadata()?.len();
            return if size == expected_size {
                Ok(size)
            } else {
                Err(StoreError::SizeMismatch)
            };
        }
        let upload_path = self.upload_path(hash);
        if upload_path.metadata()?.len() != expected_size {
            return Err(StoreError::SizeMismatch);
        }
        let size = verify_file(&upload_path, hash)?;
        let parent = final_path.parent().expect("hash path parent");
        fs::create_dir_all(parent)?;
        fs::rename(upload_path, final_path)?;
        self.connection.lock().execute(
            r#"
            INSERT INTO blobs(hash, size, verified_at)
            VALUES (?1, ?2, unixepoch())
            ON CONFLICT(hash) DO UPDATE SET size = excluded.size, verified_at = excluded.verified_at
            "#,
            params![hash.to_ascii_lowercase(), size],
        )?;
        Ok(size)
    }

    pub fn needs_loudness_analysis(
        &self,
        hash: &str,
        algorithm_version: i64,
    ) -> Result<bool, StoreError> {
        validate_hash(hash)?;
        let connection = self.connection.lock();
        let analyzed: bool = connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM loudness
                WHERE content_hash = ?1 AND algorithm_version = ?2
            )",
            params![hash, algorithm_version],
            |row| row.get(0),
        )?;
        if analyzed {
            return Ok(false);
        }
        let permanently_failed: bool = connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM loudness_analysis_failures
                WHERE content_hash = ?1 AND algorithm_version = ?2
            )",
            params![hash, algorithm_version],
            |row| row.get(0),
        )?;
        Ok(!permanently_failed)
    }

    pub fn put_loudness_analysis(
        &self,
        hash: &str,
        algorithm_version: i64,
        integrated_lufs: f64,
        peak_amplitude: f64,
        hub_id: Uuid,
    ) -> Result<(), StoreError> {
        validate_hash(hash)?;
        let analyzed_at = chrono::Utc::now().timestamp_millis() as f64 / 1_000.0;
        self.append_operations(&[Operation {
            operation_id: Uuid::new_v4(),
            device_id: hub_id,
            entity_type: "loudness".into(),
            entity_id: format!("{hash}:{algorithm_version}"),
            kind: "upsert".into(),
            payload: serde_json::json!({
                "content_hash": hash,
                "algorithm_version": algorithm_version,
                "integrated_lufs": integrated_lufs,
                "peak_amplitude": peak_amplitude,
                "analyzed_at": analyzed_at,
            }),
            field_versions: BTreeMap::new(),
        }])?;
        Ok(())
    }

    pub fn record_loudness_failure(
        &self,
        hash: &str,
        algorithm_version: i64,
        error: &str,
    ) -> Result<(), StoreError> {
        validate_hash(hash)?;
        self.connection.lock().execute(
            r#"
            INSERT INTO loudness_analysis_failures
                (content_hash, algorithm_version, error, attempted_at)
            VALUES (?1, ?2, ?3, unixepoch())
            ON CONFLICT(content_hash, algorithm_version) DO UPDATE SET
                error = excluded.error,
                attempted_at = excluded.attempted_at
            "#,
            params![hash, algorithm_version, error],
        )?;
        Ok(())
    }

    pub fn clear_loudness_failure(
        &self,
        hash: &str,
        algorithm_version: i64,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            "DELETE FROM loudness_analysis_failures
             WHERE content_hash = ?1 AND algorithm_version = ?2",
            params![hash, algorithm_version],
        )?;
        Ok(())
    }

    /// Whether `hash` still needs engineered audio-feature analysis (see
    /// `aro_track_id::audio_features`) at `algorithm_version` — same shape as
    /// [`Self::needs_loudness_analysis`]. Unlike loudness, audio features are never
    /// synced from a client (only the hub itself analyzes, since it always has direct
    /// file access to what it's scanning) — so, also unlike loudness, this is a plain
    /// local table, not a CRDT-synced one.
    pub fn needs_audio_feature_analysis(
        &self,
        hash: &str,
        algorithm_version: i64,
    ) -> Result<bool, StoreError> {
        validate_hash(hash)?;
        let connection = self.connection.lock();
        let analyzed: bool = connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM audio_features
                WHERE content_hash = ?1 AND algorithm_version = ?2
            )",
            params![hash, algorithm_version],
            |row| row.get(0),
        )?;
        if analyzed {
            return Ok(false);
        }
        let permanently_failed: bool = connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM audio_feature_failures
                WHERE content_hash = ?1 AND algorithm_version = ?2
            )",
            params![hash, algorithm_version],
            |row| row.get(0),
        )?;
        Ok(!permanently_failed)
    }

    /// Stores one track's engineered audio features (see
    /// `aro_track_id::audio_features::AudioFeatures`) as its JSON serialization —
    /// `payload_json` is opaque to this store, `playlist_seeds()` is what interprets it.
    pub fn put_audio_features(
        &self,
        hash: &str,
        algorithm_version: i64,
        payload_json: &str,
    ) -> Result<(), StoreError> {
        validate_hash(hash)?;
        self.connection.lock().execute(
            r#"
            INSERT INTO audio_features (content_hash, algorithm_version, payload)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(content_hash, algorithm_version) DO UPDATE SET
                payload = excluded.payload
            "#,
            params![hash, algorithm_version, payload_json],
        )?;
        self.connection.lock().execute(
            "DELETE FROM audio_feature_failures
             WHERE content_hash = ?1 AND algorithm_version = ?2",
            params![hash, algorithm_version],
        )?;
        Ok(())
    }

    pub fn record_audio_feature_failure(
        &self,
        hash: &str,
        algorithm_version: i64,
        error: &str,
    ) -> Result<(), StoreError> {
        validate_hash(hash)?;
        self.connection.lock().execute(
            r#"
            INSERT INTO audio_feature_failures
                (content_hash, algorithm_version, error, attempted_at)
            VALUES (?1, ?2, ?3, unixepoch())
            ON CONFLICT(content_hash, algorithm_version) DO UPDATE SET
                error = excluded.error,
                attempted_at = excluded.attempted_at
            "#,
            params![hash, algorithm_version, error],
        )?;
        Ok(())
    }

    /// One track's engineered audio features, if analyzed — keyed by content hash,
    /// the JSON payload decoded by the caller (`aro-server`'s `playlist_seeds`).
    pub fn audio_features(&self, hash: &str) -> Result<Option<String>, StoreError> {
        validate_hash(hash)?;
        Ok(self
            .connection
            .lock()
            .query_row(
                "SELECT payload FROM audio_features WHERE content_hash = ?1",
                params![hash],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// Every analyzed track's audio-feature payload, keyed by content hash — used by
    /// `playlist_seeds()` to join features onto tracks in one query rather than one
    /// per track.
    pub fn all_audio_features(&self) -> Result<HashMap<String, String>, StoreError> {
        let connection = self.connection.lock();
        let mut statement =
            connection.prepare("SELECT content_hash, payload FROM audio_features")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        rows.collect::<Result<_, _>>().map_err(Into::into)
    }

    pub fn blob_path_for_download(&self, hash: &str) -> Result<Option<PathBuf>, StoreError> {
        validate_hash(hash)?;
        let path = self.blob_path(hash);
        if path.is_file() {
            return Ok(Some(path));
        }
        let referenced = self.referenced_blob_path(hash)?;
        if let Some(path) = &referenced
            && verify_file(path, hash).is_err()
        {
            self.connection.lock().execute(
                "UPDATE referenced_blobs SET available = 0 WHERE hash = ?1",
                [hash],
            )?;
            return Ok(None);
        }
        Ok(referenced)
    }

    /// The full metadata map for a track, as materialized from its operation history.
    pub fn track_metadata(
        &self,
        track_id: Uuid,
    ) -> Result<Option<serde_json::Map<String, Value>>, StoreError> {
        let metadata: Option<String> = self
            .connection
            .lock()
            .query_row(
                "SELECT metadata FROM tracks WHERE hub_track_id = ?1",
                [track_id.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        Ok(metadata.map(|value| serde_json::from_str(&value).unwrap_or_default()))
    }

    /// The absolute on-disk path for a track's source file, if it still belongs to a
    /// watched, available source. Used to gate tag write-back: we only ever attempt to
    /// mutate a file aro can currently reach.
    /// Tracks in a metadata scope, with enough context to compare them against their files.
    ///
    /// Scope is resolved here rather than by the caller sending a list of hashes: the hub
    /// holds the catalogue, and asking a client to enumerate an artist's tracks means
    /// shipping the library over the wire to ask a question about it.
    pub fn metadata_scope_tracks(
        &self,
        artist: Option<&str>,
        album: Option<&str>,
        content_hash: Option<&str>,
        limit: u32,
    ) -> Result<Vec<MetadataScopeTrack>, StoreError> {
        let connection = self.connection.lock();
        // The manual-override rule is applied in SQL so filtering matches what the listener
        // actually sees, not the value underneath a correction they have already made.
        let effective = |field: &str| {
            format!(
                "CASE WHEN json_extract(t.metadata, '$.manual_{field}_set') = 1 \
                 THEN json_extract(t.metadata, '$.manual_{field}') \
                 ELSE json_extract(t.metadata, '$.{field}') END"
            )
        };
        let mut clauses = vec![
            "t.tombstoned_at IS NULL".to_string(),
            "t.purged_at IS NULL".to_string(),
            "t.content_hash IS NOT NULL".to_string(),
        ];
        if artist.is_some() {
            clauses.push(format!("LOWER({}) = LOWER(?1)", effective("artist")));
        }
        if album.is_some() {
            clauses.push(format!("LOWER({}) = LOWER(?2)", effective("album")));
        }
        if content_hash.is_some() {
            clauses.push("t.content_hash = ?3".to_string());
        }
        let sql = format!(
            r#"
            SELECT t.hub_track_id, t.content_hash, t.metadata,
                   (SELECT sources.path || '/' || source_files.relative_path
                    FROM source_files
                    JOIN sources ON sources.source_id = source_files.source_id
                    WHERE source_files.hub_track_id = t.hub_track_id
                      AND source_files.available = 1
                      AND sources.available = 1
                      AND sources.detached_at IS NULL
                      AND sources.path IS NOT NULL
                    LIMIT 1),
                   EXISTS(SELECT 1 FROM blobs b WHERE b.hash = t.content_hash)
            FROM tracks t
            WHERE {}
            ORDER BY t.hub_track_id
            LIMIT ?4
            "#,
            clauses.join(" AND ")
        );
        let mut statement = connection.prepare(&sql)?;
        let rows = statement
            .query_map(
                params![
                    artist.unwrap_or_default(),
                    album.unwrap_or_default(),
                    content_hash.unwrap_or_default(),
                    limit.clamp(1, 2_000)
                ],
                |row| {
                    Ok(MetadataScopeTrack {
                        track_id: row
                            .get::<_, String>(0)?
                            .parse()
                            .unwrap_or_else(|_| Uuid::nil()),
                        content_hash: row.get(1)?,
                        metadata: serde_json::from_str(&row.get::<_, String>(2)?)
                            .unwrap_or(Value::Null),
                        original_path: row.get(3)?,
                        hub_copy: row.get(4)?,
                    })
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Which tracks an identification sweep should cover.
    ///
    /// Scope is resolved here rather than by the client, because the hub is what holds the
    /// catalogue: "identify everything by this artist" is a question about the library, and
    /// answering it client-side means sending the library over the wire first.
    ///
    /// Ordered newest-first by rowid so a sweep that is watched rather than waited out
    /// starts with the tracks most likely to have just arrived.
    pub fn identification_scope(
        &self,
        artist: Option<&str>,
        album: Option<&str>,
        include_identified: bool,
    ) -> Result<Vec<(String, Uuid)>, StoreError> {
        let connection = self.connection.lock();
        let effective = |field: &str| {
            format!(
                "CASE WHEN json_extract(t.metadata, '$.manual_{field}_set') = 1 \
                 THEN json_extract(t.metadata, '$.manual_{field}') \
                 ELSE json_extract(t.metadata, '$.{field}') END"
            )
        };
        let mut clauses = vec![
            "t.tombstoned_at IS NULL".to_string(),
            "t.purged_at IS NULL".to_string(),
            "t.content_hash IS NOT NULL".to_string(),
        ];
        // Bound positionally and only when present: an unscoped sweep is the common case,
        // and its SQL carries no placeholders at all, so binding a fixed pair would make
        // "identify everything" the one call that always fails.
        let mut bindings: Vec<&str> = Vec::new();
        if let Some(artist) = artist {
            clauses.push(format!("LOWER({}) = LOWER(?)", effective("artist")));
            bindings.push(artist);
        }
        if let Some(album) = album {
            clauses.push(format!("LOWER({}) = LOWER(?)", effective("album")));
            bindings.push(album);
        }
        if !include_identified {
            clauses.push(
                "NOT EXISTS(SELECT 1 FROM identification_results r \
                 WHERE r.content_hash = t.content_hash)"
                    .to_string(),
            );
        }
        let sql = format!(
            "SELECT t.content_hash, t.hub_track_id FROM tracks t WHERE {} ORDER BY t.rowid DESC",
            clauses.join(" AND ")
        );
        let mut statement = connection.prepare(&sql)?;
        let rows = statement
            .query_map(rusqlite::params_from_iter(bindings), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?
                        .parse()
                        .unwrap_or_else(|_| Uuid::nil()),
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn live_path_for_track(&self, track_id: Uuid) -> Result<Option<PathBuf>, StoreError> {
        let row: Option<(String, String)> = self
            .connection
            .lock()
            .query_row(
                r#"
                SELECT sources.path, source_files.relative_path
                FROM source_files
                JOIN sources ON sources.source_id = source_files.source_id
                WHERE source_files.hub_track_id = ?1
                  AND source_files.available = 1
                  AND sources.available = 1
                  AND sources.detached_at IS NULL
                  AND sources.path IS NOT NULL
                LIMIT 1
                "#,
                [track_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        Ok(row
            .map(|(base, relative)| Path::new(&base).join(relative))
            .filter(|path| path.is_file()))
    }

    pub fn identification_cache_get(
        &self,
        fingerprint: &str,
    ) -> Result<Option<IdentificationCacheEntry>, StoreError> {
        self.connection
            .lock()
            .query_row(
                r#"
                SELECT acoustid_response, musicbrainz_response, schema_version, refreshed_at
                FROM identification_cache
                WHERE fingerprint = ?1
                "#,
                [fingerprint],
                |row| {
                    let acoustid: Option<String> = row.get(0)?;
                    let musicbrainz: Option<String> = row.get(1)?;
                    Ok(IdentificationCacheEntry {
                        acoustid_response: acoustid
                            .and_then(|value| serde_json::from_str(&value).ok()),
                        musicbrainz_response: musicbrainz
                            .and_then(|value| serde_json::from_str(&value).ok()),
                        schema_version: row.get::<_, i64>(2)? as u32,
                        refreshed_at: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn identification_cache_put(
        &self,
        fingerprint: &str,
        acoustid_response: Option<&Value>,
        musicbrainz_response: Option<&Value>,
        schema_version: u32,
    ) -> Result<(), StoreError> {
        let now = chrono::Utc::now().timestamp();
        self.connection.lock().execute(
            r#"
            INSERT INTO identification_cache
                (fingerprint, acoustid_response, musicbrainz_response, schema_version, created_at, refreshed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?5)
            ON CONFLICT(fingerprint) DO UPDATE SET
                acoustid_response = excluded.acoustid_response,
                musicbrainz_response = excluded.musicbrainz_response,
                schema_version = excluded.schema_version,
                refreshed_at = excluded.refreshed_at
            "#,
            params![
                fingerprint,
                acoustid_response.map(Value::to_string),
                musicbrainz_response.map(Value::to_string),
                schema_version,
                now,
            ],
        )?;
        Ok(())
    }

    /// The cached `ws/2/release/{id}` response for `release_id`, if one has ever been
    /// successfully fetched. `None` both when nothing is cached and when the stored JSON
    /// fails to parse — a corrupt row is treated the same as "not cached", matching
    /// `identification_cache_get`'s convention.
    pub fn release_cache_get(
        &self,
        release_id: &str,
    ) -> Result<Option<ReleaseCacheEntry>, StoreError> {
        let row = self
            .connection
            .lock()
            .query_row(
                r#"
                SELECT response, schema_version, refreshed_at
                FROM musicbrainz_release_cache
                WHERE release_id = ?1
                "#,
                [release_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)? as u32,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?;
        Ok(row.and_then(|(response, schema_version, refreshed_at)| {
            serde_json::from_str(&response)
                .ok()
                .map(|response| ReleaseCacheEntry {
                    response,
                    schema_version,
                    refreshed_at,
                })
        }))
    }

    pub fn release_cache_put(
        &self,
        release_id: &str,
        response: &Value,
        schema_version: u32,
    ) -> Result<(), StoreError> {
        let now = chrono::Utc::now().timestamp();
        self.connection.lock().execute(
            r#"
            INSERT INTO musicbrainz_release_cache
                (release_id, response, schema_version, created_at, refreshed_at)
            VALUES (?1, ?2, ?3, ?4, ?4)
            ON CONFLICT(release_id) DO UPDATE SET
                response = excluded.response,
                schema_version = excluded.schema_version,
                refreshed_at = excluded.refreshed_at
            "#,
            params![release_id, response.to_string(), schema_version, now],
        )?;
        Ok(())
    }

    pub fn recording_cache_get(
        &self,
        recording_id: &str,
    ) -> Result<Option<RecordingCacheEntry>, StoreError> {
        let row = self
            .connection
            .lock()
            .query_row(
                r#"
                SELECT response, schema_version, refreshed_at
                FROM musicbrainz_recording_cache
                WHERE recording_id = ?1
                "#,
                [recording_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)? as u32,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?;
        Ok(row.and_then(|(response, schema_version, refreshed_at)| {
            serde_json::from_str(&response)
                .ok()
                .map(|response| RecordingCacheEntry {
                    response,
                    schema_version,
                    refreshed_at,
                })
        }))
    }

    pub fn recording_cache_put(
        &self,
        recording_id: &str,
        response: &Value,
        schema_version: u32,
    ) -> Result<(), StoreError> {
        let now = chrono::Utc::now().timestamp();
        self.connection.lock().execute(
            r#"
            INSERT INTO musicbrainz_recording_cache
                (recording_id, response, schema_version, created_at, refreshed_at)
            VALUES (?1, ?2, ?3, ?4, ?4)
            ON CONFLICT(recording_id) DO UPDATE SET
                response = excluded.response,
                schema_version = excluded.schema_version,
                refreshed_at = excluded.refreshed_at
            "#,
            params![recording_id, response.to_string(), schema_version, now],
        )?;
        Ok(())
    }

    /// Increments (creating if absent) the automatic group-retry attempt counter for
    /// `folder`, returning the new count. `aro_track_id::queue::reconcile_sweep` uses this
    /// to bound how many times it will automatically re-attempt a folder whose group match
    /// was rejected outright (see `folders_needing_group_retry`) — without a cap, a folder
    /// that can never converge (a genuine mixed bag, correctly rejected every time by
    /// `album::accept`) would be retried on every sweep forever, burning AcoustID/
    /// MusicBrainz request budget for no gain.
    pub fn record_group_reconcile_attempt(&self, folder: &Path) -> Result<i64, StoreError> {
        let now = chrono::Utc::now().timestamp();
        let folder = folder.to_string_lossy();
        self.connection.lock().execute(
            r#"
            INSERT INTO group_reconcile_attempts (folder, attempts, last_attempted_at)
            VALUES (?1, 1, ?2)
            ON CONFLICT(folder) DO UPDATE SET
                attempts = group_reconcile_attempts.attempts + 1,
                last_attempted_at = excluded.last_attempted_at
            "#,
            params![folder.as_ref(), now],
        )?;
        let attempts = self.connection.lock().query_row(
            "SELECT attempts FROM group_reconcile_attempts WHERE folder = ?1",
            [folder.as_ref()],
            |row| row.get(0),
        )?;
        Ok(attempts)
    }

    /// Distinct folders with at least `min_group_members` available files, none of which
    /// have ever landed a `group`-sourced (accepted) identification -- i.e. a folder whose
    /// group match was attempted and rejected outright (every member fell back to the
    /// unscored per-file path), not one that simply hasn't been scanned yet (`resolution_source`
    /// is `NULL`/absent) or one that mostly succeeded with a few genuine outliers (which
    /// would have at least one `group`-sourced member). Excludes folders that have already
    /// exhausted `max_attempts` automatic retries (see `record_group_reconcile_attempt`).
    /// Ordered by member count descending, same rationale as `folders_needing_reconcile`.
    pub fn folders_needing_group_retry(
        &self,
        min_group_members: i64,
        max_attempts: i64,
        limit: u32,
    ) -> Result<Vec<PathBuf>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT sources.path, source_files.relative_path,
                   count(*) AS member_count,
                   sum(CASE WHEN ir.resolution_source = 'per_file' THEN 1 ELSE 0 END)
                       AS per_file_count
            FROM source_files
            JOIN sources ON sources.source_id = source_files.source_id
            JOIN identification_results ir ON ir.content_hash = source_files.content_hash
            WHERE source_files.available = 1
              AND sources.path IS NOT NULL
            GROUP BY sources.path, source_files.relative_path
            HAVING count(*) = sum(CASE WHEN ir.resolution_source = 'per_file' THEN 1 ELSE 0 END)
            "#,
        )?;
        let rows: Vec<(String, String, i64)> = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<Result<_, _>>()?;
        drop(statement);

        let mut counts: HashMap<PathBuf, i64> = HashMap::new();
        for (source_path, relative_path, member_count) in rows {
            let full_path = Path::new(&source_path).join(relative_path);
            if let Some(folder) = full_path.parent() {
                *counts.entry(folder.to_path_buf()).or_insert(0) += member_count;
            }
        }

        let mut attempts_statement = connection
            .prepare("SELECT attempts FROM group_reconcile_attempts WHERE folder = ?1")?;
        let mut folders: Vec<(PathBuf, i64)> = counts
            .into_iter()
            .filter(|(_, member_count)| *member_count >= min_group_members)
            .filter(|(folder, _)| {
                let attempts: Option<i64> = attempts_statement
                    .query_row([folder.to_string_lossy().as_ref()], |row| row.get(0))
                    .optional()
                    .unwrap_or(None);
                attempts.unwrap_or(0) < max_attempts
            })
            .collect();
        drop(attempts_statement);

        folders.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        Ok(folders
            .into_iter()
            .take(limit.clamp(1, 1_000) as usize)
            .map(|(folder, _)| folder)
            .collect())
    }

    /// Every scanned, available file whose parent directory is exactly `folder` — the
    /// folder's whole membership, independent of which specific files were offered to
    /// `IdentificationQueue::enqueue` on any one scan pass. This is what lets a manually
    /// re-synced single file pull in the rest of its folder as group context, rather than
    /// only ever seeing the one file a caller happened to name.
    ///
    /// Scans every `source_files` row across every source, rather than an indexed
    /// per-folder lookup — there's no path-prefix index today, and doing real directory
    /// comparison (rather than a fragile SQL string-prefix match) needs `Path::parent()` in
    /// Rust. Acceptable because this runs once per group, not once per file, against
    /// libraries in the hundreds-to-low-thousands of tracks this crate targets — not a
    /// per-file hot path.
    pub fn folder_members(&self, folder: &Path) -> Result<Vec<FolderMember>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT sources.path, source_files.relative_path, source_files.content_hash
            FROM source_files
            JOIN sources ON sources.source_id = source_files.source_id
            WHERE source_files.available = 1 AND sources.path IS NOT NULL
            "#,
        )?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows
            .into_iter()
            .filter_map(|(source_path, relative_path, content_hash)| {
                let full_path = Path::new(&source_path).join(relative_path);
                (full_path.parent() == Some(folder)).then_some(FolderMember {
                    path: full_path,
                    content_hash,
                })
            })
            .collect())
    }

    /// The identification result for one file, if it's ever been identified — the
    /// singular counterpart to [`Self::identification_results_since`], used to read a
    /// specific sibling file's already-computed answer (e.g. for sibling-consensus
    /// grouping) rather than pulling every result since some cursor.
    pub fn identification_result(
        &self,
        content_hash: &str,
    ) -> Result<Option<IdentificationResult>, StoreError> {
        self.connection
            .lock()
            .query_row(
                r#"
                SELECT content_hash, title, artist, album, artwork_url,
                       musicbrainz_recording_id, acoustid_id, identified_at,
                       resolution_source, resolution_score, resolution_generation,
                       release_id, release_group_id, musicbrainz_genres, mood_tags
                FROM identification_results
                WHERE content_hash = ?1
                "#,
                [content_hash],
                identification_result_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    /// Advances `content_hash`'s `resolution_generation` to `generation`, without touching
    /// any other field — a no-op if it's already at or beyond `generation`, or if the file
    /// has no identification result at all. Used by a reconcile sweep to mark a file "seen
    /// at this generation" even when its existing answer was kept in place (see
    /// `aro_track_id::queue::should_revise`), so it isn't re-offered to every future sweep
    /// forever — without this, a file whose answer is correctly never revised would never
    /// leave `folders_needing_reconcile`'s result set.
    pub fn touch_identification_generation(
        &self,
        content_hash: &str,
        generation: i64,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            "UPDATE identification_results SET resolution_generation = ?1 \
             WHERE content_hash = ?2 AND resolution_generation < ?1",
            params![generation, content_hash],
        )?;
        Ok(())
    }

    /// Content hash / release id pairs for results that were correctly identified (a
    /// release was resolved) but never got artwork cached -- `aro_track_id::queue`'s
    /// `cache_artwork` is a best-effort side effect of the *first* write for a group or
    /// per-file result (network error, Cover Art Archive outage, etc. all just leave
    /// `artwork_url` `NULL` rather than failing the whole identification, since artwork is
    /// decorative), and nothing else ever revisits it once the release itself is settled --
    /// an already-`group`-sourced result never re-enters `folders_needing_group_retry`, and
    /// a stale-generation reconcile only fires for files below the current generation. This
    /// is what a periodic artwork backfill (see `aro_track_id::queue::backfill_missing_artwork`)
    /// reads from to give that one-off failure a real second chance.
    pub fn identification_results_missing_artwork(
        &self,
        limit: u32,
    ) -> Result<Vec<(String, String, Option<String>)>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT content_hash, release_id, release_group_id
            FROM identification_results
            WHERE release_id IS NOT NULL AND artwork_url IS NULL
            LIMIT ?1
            "#,
        )?;
        let rows = statement
            .query_map([limit.clamp(1, 10_000)], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }

    /// Fills in `artwork_url` for a result that was missing it, without touching any other
    /// field -- guarded by `artwork_url IS NULL` so a concurrent normal identification write
    /// (which sets every field, including artwork, together) always wins over this
    /// best-effort backfill rather than the two racing to stomp each other.
    ///
    /// Also advances `identified_at` to now: `identification_results_since` (what clients
    /// poll to pull new/changed results) is a pure `identified_at > cursor` query, not a
    /// real "last modified" check -- a client that already pulled this row once, back when
    /// artwork_url was still `NULL`, has already advanced its cursor past it, and would
    /// never see this backfill happen no matter how long it keeps polling unless this row
    /// looks "new" again. `identified_at` is never shown to users as a real timestamp (it's
    /// purely this sync cursor), so bumping it here is safe.
    pub fn set_artwork_url(&self, content_hash: &str, artwork_url: &str) -> Result<(), StoreError> {
        self.connection.lock().execute(
            "UPDATE identification_results SET artwork_url = ?1, identified_at = ?2 \
             WHERE content_hash = ?3 AND artwork_url IS NULL",
            params![artwork_url, chrono::Utc::now().timestamp(), content_hash],
        )?;
        Ok(())
    }

    pub fn has_identification_result(&self, content_hash: &str) -> Result<bool, StoreError> {
        Ok(self
            .connection
            .lock()
            .query_row(
                "SELECT 1 FROM identification_results WHERE content_hash = ?1",
                [content_hash],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    pub fn put_identification_result(
        &self,
        result: &IdentificationResult,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO identification_results
                (content_hash, title, artist, album, artwork_url,
                 musicbrainz_recording_id, acoustid_id, identified_at,
                 resolution_source, resolution_score, resolution_generation,
                 release_id, release_group_id, musicbrainz_genres, mood_tags)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(content_hash) DO UPDATE SET
                title = excluded.title,
                artist = excluded.artist,
                album = excluded.album,
                artwork_url = excluded.artwork_url,
                musicbrainz_recording_id = excluded.musicbrainz_recording_id,
                acoustid_id = excluded.acoustid_id,
                identified_at = excluded.identified_at,
                resolution_source = excluded.resolution_source,
                resolution_score = excluded.resolution_score,
                resolution_generation = excluded.resolution_generation,
                release_id = excluded.release_id,
                release_group_id = excluded.release_group_id,
                musicbrainz_genres = excluded.musicbrainz_genres,
                mood_tags = excluded.mood_tags
            "#,
            params![
                result.content_hash,
                result.title,
                result.artist,
                result.album,
                result.artwork_url,
                result.musicbrainz_recording_id,
                result.acoustid_id,
                result.identified_at,
                result.resolution_source,
                result.resolution_score,
                result.resolution_generation,
                result.release_id,
                result.release_group_id,
                result.musicbrainz_genres,
                result.mood_tags,
            ],
        )?;
        Ok(())
    }

    /// Results identified after `after` (exclusive), oldest first — the pull side of
    /// the bridge the macOS app polls to merge results into its own local library
    /// catalog, since content hash (not any track id) is the only shared key.
    /// Results recorded after `after` (exclusive), oldest first.
    ///
    /// `limit` is a *soft* page size: the batch is extended to include every row
    /// sharing the last row's `identified_at`, so it can overshoot slightly. That
    /// matters because `identified_at` is not unique — a folder identified as one
    /// group stamps every track in it with the same instant — and callers page by
    /// advancing a cursor to the newest `identified_at` they've seen. A hard `LIMIT`
    /// can truncate in the middle of such a group, and the caller then advances past
    /// that timestamp and never sees the remainder: those tracks silently keep their
    /// stale metadata and placeholder artwork forever. Returning whole timestamp
    /// groups makes advancing the cursor safe by construction.
    pub fn identification_results_since(
        &self,
        after: i64,
        limit: u32,
    ) -> Result<Vec<IdentificationResult>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT content_hash, title, artist, album, artwork_url,
                   musicbrainz_recording_id, acoustid_id, identified_at,
                   resolution_source, resolution_score, resolution_generation,
                   release_id, release_group_id, musicbrainz_genres, mood_tags
            FROM identification_results
            WHERE identified_at > ?1
              AND identified_at <= (
                  SELECT MAX(identified_at) FROM (
                      SELECT identified_at
                      FROM identification_results
                      WHERE identified_at > ?1
                      ORDER BY identified_at
                      LIMIT ?2
                  )
              )
            ORDER BY identified_at
            "#,
        )?;
        let rows = statement.query_map(
            params![after, limit.clamp(1, 1_000)],
            identification_result_from_row,
        )?;
        rows.collect::<Result<_, _>>().map_err(Into::into)
    }

    /// Distinct folders (parent directories of `source_files.relative_path`) containing at
    /// least one file whose `identification_results.resolution_generation` is below
    /// `generation` — i.e. folders a reconcile pass at `generation` hasn't touched yet.
    /// Ordered by member count descending, matching the coalescer's largest-folder-first
    /// flush order (see `aro_track_id::queue`) so a reconcile sweep seeds affinity the same
    /// way a cold-start pass does. Files with no identification result at all are not
    /// counted — reconcile revises existing answers, it doesn't identify new files (that
    /// remains `sources.rs::maybe_enqueue_identification`'s job).
    pub fn folders_needing_reconcile(
        &self,
        generation: i64,
        limit: u32,
    ) -> Result<Vec<PathBuf>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            SELECT sources.path, source_files.relative_path, count(*) AS member_count
            FROM source_files
            JOIN sources ON sources.source_id = source_files.source_id
            JOIN identification_results ir ON ir.content_hash = source_files.content_hash
            WHERE source_files.available = 1
              AND sources.path IS NOT NULL
              AND ir.resolution_generation < ?1
            GROUP BY sources.path, source_files.relative_path
            "#,
        )?;
        let rows: Vec<(String, String, i64)> = statement
            .query_map([generation], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?
            .collect::<Result<_, _>>()?;

        // Grouping by exact relative path over-counts (each file is its own "folder" by
        // that key), so fold to actual parent directories in Rust, same reasoning as
        // `folder_members`'s doc comment on why this isn't done in SQL.
        let mut counts: HashMap<PathBuf, i64> = HashMap::new();
        for (source_path, relative_path, member_count) in rows {
            let full_path = Path::new(&source_path).join(relative_path);
            if let Some(folder) = full_path.parent() {
                *counts.entry(folder.to_path_buf()).or_insert(0) += member_count;
            }
        }
        let mut folders: Vec<(PathBuf, i64)> = counts.into_iter().collect();
        folders.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        Ok(folders
            .into_iter()
            .take(limit.clamp(1, 1_000) as usize)
            .map(|(folder, _)| folder)
            .collect())
    }

    pub fn verify_all(&self) -> Result<(usize, Vec<String>), StoreError> {
        let hashes: Vec<String> = {
            let connection = self.connection.lock();
            let mut statement = connection.prepare("SELECT hash FROM blobs ORDER BY hash")?;
            statement
                .query_map([], |row| row.get(0))?
                .collect::<Result<_, _>>()?
        };
        let mut failures = Vec::new();
        for hash in &hashes {
            if verify_file(&self.blob_path(hash), hash).is_err() {
                failures.push(hash.clone());
            }
        }
        let referenced: Vec<(String, String)> = {
            let connection = self.connection.lock();
            let mut statement =
                connection.prepare("SELECT hash, path FROM referenced_blobs ORDER BY hash")?;
            statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<Result<_, _>>()?
        };
        for (hash, path) in &referenced {
            if verify_file(Path::new(path), hash).is_err() {
                failures.push(hash.clone());
            }
        }
        Ok((hashes.len() + referenced.len(), failures))
    }

    pub fn set_setting(&self, key: &str, value: &Value) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO settings(key, value) VALUES (?1, ?2)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            "#,
            params![key, value.to_string()],
        )?;
        Ok(())
    }

    pub fn setting(&self, key: &str) -> Result<Option<Value>, StoreError> {
        let json: Option<String> = self
            .connection
            .lock()
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |row| {
                row.get(0)
            })
            .optional()?;
        Ok(json.and_then(|value| serde_json::from_str(&value).ok()))
    }

    /// Records that `content_hash` resolved to `release_group_id` for
    /// `artist_normalized`. Used by `aro-track-id`'s "Intelligent" album-matching mode
    /// to let a release-group that already has several of an artist's tracks pull in the
    /// rest, instead of each track picking independently. Never overwrites
    /// `release_title` with `None` — later calls for the same release-group may not
    /// always have a title on hand, but earlier ones did.
    ///
    /// The tally is the number of *distinct tracks* that chose this release-group, not
    /// the number of times identification has run. Re-identifying the same track (a new
    /// generation, a manual re-scan, a retry) has to leave the tally where it was:
    /// otherwise affinity measures how often the queue has run rather than how much of
    /// the artist's music actually lives on that release, and grows without bound.
    pub fn record_release_group_choice(
        &self,
        artist_normalized: &str,
        release_group_id: &str,
        release_title: Option<&str>,
        content_hash: &str,
    ) -> Result<(), StoreError> {
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        // A track belongs to one release-group at a time, so re-identifying it has to move
        // its vote rather than add another. Without this a track that was filed wrongly
        // keeps voting for the wrong album forever, and affinity — a ranking tier in both
        // `select_release` and `shortlist_candidates` — keeps handing that album standing
        // it has lost, which is exactly how a mistake makes itself permanent.
        let previous: Vec<(String, String)> = {
            let mut statement = transaction.prepare(
                "SELECT artist_normalized, release_group_id \
                 FROM release_group_affinity_members WHERE content_hash = ?1",
            )?;
            statement
                .query_map([content_hash], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        // Cleared across every artist, not just this one: a manual artist edit changes the
        // normalized key, which would otherwise strand the old rows unreachable.
        transaction.execute(
            "DELETE FROM release_group_affinity_members WHERE content_hash = ?1",
            params![content_hash],
        )?;
        transaction.execute(
            r#"
            INSERT OR IGNORE INTO release_group_affinity_members
                (artist_normalized, release_group_id, content_hash)
            VALUES (?1, ?2, ?3)
            "#,
            params![artist_normalized, release_group_id, content_hash],
        )?;
        transaction.execute(
            r#"
            INSERT INTO release_group_affinity(artist_normalized, release_group_id, release_title, track_count)
            VALUES (?1, ?2, ?3, 1)
            ON CONFLICT(artist_normalized, release_group_id) DO UPDATE SET
                release_title = COALESCE(excluded.release_title, release_group_affinity.release_title),
                track_count = (
                    SELECT COUNT(*) FROM release_group_affinity_members AS members
                    WHERE members.artist_normalized = ?1
                      AND members.release_group_id = ?2
                )
            "#,
            params![artist_normalized, release_group_id, release_title],
        )?;
        // Every group this track has just left needs its tally corrected too — the upsert
        // above only recomputes the group it moved to.
        for (previous_artist, previous_group) in previous {
            if previous_artist == artist_normalized && previous_group == release_group_id {
                continue;
            }
            transaction.execute(
                r#"
                UPDATE release_group_affinity SET track_count = (
                    SELECT COUNT(*) FROM release_group_affinity_members AS members
                    WHERE members.artist_normalized = ?1
                      AND members.release_group_id = ?2
                )
                WHERE artist_normalized = ?1 AND release_group_id = ?2
                "#,
                params![previous_artist, previous_group],
            )?;
        }
        transaction.execute(
            "DELETE FROM release_group_affinity WHERE track_count <= 0",
            [],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// The blob holding `content_hash` already encoded at `quality`, if one exists.
    ///
    /// Transcoding is expensive enough to be worth never repeating: the reference hub
    /// manages 6.5–8.7× realtime, so a three-minute track costs 20–30 seconds of CPU before
    /// the source is even decoded. Cached, a re-play is an ordinary blob read — which also
    /// restores range requests and therefore seeking, which a stream still being encoded
    /// cannot support.
    pub fn transcoded_blob(
        &self,
        content_hash: &str,
        quality: &str,
    ) -> Result<Option<String>, StoreError> {
        Ok(self
            .connection
            .lock()
            .query_row(
                "SELECT blob_hash FROM transcoded_blobs WHERE content_hash = ?1 AND quality = ?2",
                params![content_hash, quality],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }

    /// Live tracks with no encode yet at `quality`, as (content hash, duration seconds).
    /// Duration drives the time estimate shown before a conversion is agreed to, so it is
    /// returned here rather than recomputed by the caller.
    pub fn tracks_missing_transcode(
        &self,
        quality: &str,
    ) -> Result<Vec<(String, f64)>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            r#"
            -- The field is `duration`; `duration_seconds` is the *catalog* projection's
            -- name for it. Reading the wrong one yields NULL rather than an error, which
            -- silently quotes every conversion as taking no time at all.
            SELECT tracks.content_hash,
                   COALESCE(
                       json_extract(tracks.metadata, '$.duration'),
                       json_extract(tracks.metadata, '$.duration_seconds'),
                       0
                   )
            FROM tracks
            WHERE tracks.tombstoned_at IS NULL
              AND tracks.purged_at IS NULL
              AND tracks.content_hash IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM transcoded_blobs
                  WHERE transcoded_blobs.content_hash = tracks.content_hash
                    AND transcoded_blobs.quality = ?1
              )
            "#,
        )?;
        let rows = statement
            .query_map([quality], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, f64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Every encode held at qualities other than `keep`, so a listener who moves back up
    /// the ladder can reclaim the space rather than silently keeping copies they will never
    /// play again. Returns what was removed and how many bytes it freed.
    pub fn purge_transcodes_except(&self, keep: &str) -> Result<(u64, u64), StoreError> {
        let doomed: Vec<(String, u64)> = {
            let connection = self.connection.lock();
            let mut statement = connection.prepare(
                "SELECT blob_hash, byte_count FROM transcoded_blobs WHERE quality <> ?1",
            )?;
            statement
                .query_map([keep], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        self.connection
            .lock()
            .execute("DELETE FROM transcoded_blobs WHERE quality <> ?1", [keep])?;
        let mut removed = 0u64;
        let mut freed = 0u64;
        for (blob_hash, bytes) in doomed {
            // Deleting the row first means `purge_blob` no longer counts it as referenced.
            // A blob shared with something else (the same encode reached from two rows)
            // stays put, which is what `purge_blob` returning `BlobReferenced` expresses.
            match self.purge_blob(&blob_hash) {
                Ok(true) => {
                    removed += 1;
                    freed += bytes;
                }
                Ok(false) | Err(StoreError::BlobReferenced) => {}
                Err(error) => return Err(error),
            }
        }
        Ok((removed, freed))
    }

    /// How much disk the encodes at each quality are using, for the settings screen and the
    /// dashboard.
    pub fn transcode_usage(&self) -> Result<Vec<(String, u64, u64)>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            "SELECT quality, COUNT(*), COALESCE(SUM(byte_count), 0) \
             FROM transcoded_blobs GROUP BY quality ORDER BY quality",
        )?;
        let rows = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn record_transcoded_blob(
        &self,
        content_hash: &str,
        quality: &str,
        blob_hash: &str,
        byte_count: u64,
    ) -> Result<(), StoreError> {
        let byte_count = byte_count.min(i64::MAX as u64);
        self.connection.lock().execute(
            r#"
            INSERT INTO transcoded_blobs(content_hash, quality, blob_hash, byte_count, created_at)
            VALUES (?1, ?2, ?3, ?4, unixepoch())
            ON CONFLICT(content_hash, quality) DO UPDATE SET
                blob_hash = excluded.blob_hash,
                byte_count = excluded.byte_count,
                created_at = excluded.created_at
            "#,
            params![content_hash, quality, blob_hash, byte_count],
        )?;
        Ok(())
    }

    /// A previously-discovered artwork candidate list, if one was cached. Discovery costs
    /// dozens of rate-limited MusicBrainz and Cover Art Archive requests — well over a
    /// minute for a prolific artist — so reopening the picker must not repeat it.
    pub fn cached_artwork_candidates(&self, cache_key: &str) -> Result<Option<String>, StoreError> {
        Ok(self
            .connection
            .lock()
            .query_row(
                "SELECT response FROM artwork_candidate_cache WHERE cache_key = ?1",
                [cache_key],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }

    pub fn cache_artwork_candidates(
        &self,
        cache_key: &str,
        response: &str,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO artwork_candidate_cache(cache_key, response, refreshed_at)
            VALUES (?1, ?2, unixepoch())
            ON CONFLICT(cache_key) DO UPDATE SET
                response = excluded.response,
                refreshed_at = excluded.refreshed_at
            "#,
            params![cache_key, response],
        )?;
        Ok(())
    }

    /// The release-group affinity tally for `artist_normalized`, keyed by
    /// release-group id, as recorded by `record_release_group_choice`.
    pub fn release_group_affinity(
        &self,
        artist_normalized: &str,
    ) -> Result<HashMap<String, i64>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            "SELECT release_group_id, track_count FROM release_group_affinity \
             WHERE artist_normalized = ?1",
        )?;
        let rows = statement
            .query_map([artist_normalized], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }

    /// The raw per-release-group affinity rows for `artist_normalized`, including each
    /// row's title. Unlike [`Self::release_group_affinity`], which only exposes the
    /// id-keyed tally, this keeps `release_title` alongside each id so a caller can
    /// consolidate rows that are really the same album under two or more distinct
    /// MusicBrainz release-group ids (observed directly: three different release-group ids
    /// all titled "The Beatles" for one artist, splitting what should be one affinity
    /// signal into three weaker ones) — see `aro_track_id::musicbrainz::AffinityIndex`,
    /// which is what actually performs that consolidation. This store deliberately doesn't
    /// fold Unicode punctuation variants itself (see [`Self::release_title_affinity`]), so
    /// that consolidation has to happen in the caller.
    pub fn release_group_affinity_rows(
        &self,
        artist_normalized: &str,
    ) -> Result<Vec<ReleaseGroupAffinityRow>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            "SELECT release_group_id, release_title, track_count FROM release_group_affinity \
             WHERE artist_normalized = ?1",
        )?;
        let rows = statement
            .query_map([artist_normalized], |row| {
                Ok(ReleaseGroupAffinityRow {
                    release_group_id: row.get(0)?,
                    release_title: row.get(1)?,
                    track_count: row.get(2)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(rows)
    }

    /// Distinct release titles (trimmed, lowercased) that `artist_normalized`
    /// already has affinity for, per `record_release_group_choice`. Unlike
    /// `release_group_affinity`, this is keyed by title rather than
    /// release-group id — `aro-track-id::acoustid::best_recording` uses it to
    /// disambiguate between two different MusicBrainz *recordings* that share
    /// an identical title (AcoustID's payload carries release-group titles per
    /// candidate recording, but not release-group ids). Rows with no
    /// `release_title` are excluded since they can't be matched against
    /// anything. Callers apply their own further normalization on top (see
    /// `aro-track-id::matching::normalize_matching_key`) since this store
    /// deliberately doesn't fold Unicode punctuation variants itself.
    pub fn release_title_affinity(
        &self,
        artist_normalized: &str,
    ) -> Result<HashSet<String>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            "SELECT DISTINCT release_title FROM release_group_affinity \
             WHERE artist_normalized = ?1 AND release_title IS NOT NULL",
        )?;
        let rows = statement
            .query_map([artist_normalized], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows
            .into_iter()
            .map(|title| title.trim().to_lowercase())
            .collect())
    }

    /// Moves everything Aro knows about a track from one content hash to another.
    ///
    /// Content hash is the identity of a track everywhere in this system: it keys the blob
    /// store, the source-file index, loudness and audio-feature analysis, identification
    /// results, release-group affinity, cached transcodes, and the hash lists inside
    /// generated playlists. It is the SHA-256 of the *whole file*, tags included — so
    /// writing corrected tags back to a file changes the track's identity in every one of
    /// those places at once.
    ///
    /// Without this, a single tag write means: the file fails verification and is marked
    /// unavailable the next time it is served; the next scan re-imports it as a *new*
    /// track, leaving a second full copy of the audio in managed mode; loudness, features
    /// and every cached encode are orphaned and recomputed; and two identical files that
    /// previously de-duplicated to one track silently become two.
    ///
    /// One transaction, because a partial migration is worse than none: it would leave the
    /// track playable but strip its history, or leave history pointing at bytes that no
    /// longer exist.
    ///
    /// Identification is deliberately *not* carried across — the caller re-identifies, so
    /// the row for `old` is dropped rather than moved. That is safe from looping only
    /// because tag write-back is always user-initiated; nothing in the pipeline writes tags
    /// on its own, so a re-identification cannot trigger another write.
    pub fn rekey_content_hash(&self, old: &str, new: &str) -> Result<(), StoreError> {
        validate_hash(old)?;
        validate_hash(new)?;
        if old == new {
            return Ok(());
        }
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;

        // Anything already recorded under the new hash wins: the file's current bytes are
        // the truth, and a stale row from a previous life of that hash must not survive to
        // conflict with it.
        for table in [
            "loudness",
            "loudness_analysis_failures",
            "audio_features",
            "audio_feature_failures",
            "identification_results",
            "release_group_affinity_members",
            "transcoded_blobs",
        ] {
            transaction.execute(
                &format!("DELETE FROM {table} WHERE content_hash = ?1"),
                [new],
            )?;
        }
        transaction.execute("DELETE FROM blobs WHERE hash = ?1", [new])?;
        transaction.execute("DELETE FROM referenced_blobs WHERE hash = ?1", [new])?;

        // Analysis and derived data follow the bytes: the audio is unchanged by a tag
        // edit, so loudness and features remain valid, and re-deriving them would be
        // minutes of needless work on a slow hub.
        for table in [
            "loudness",
            "loudness_analysis_failures",
            "audio_features",
            "audio_feature_failures",
            "release_group_affinity_members",
            "transcoded_blobs",
        ] {
            transaction.execute(
                &format!("UPDATE {table} SET content_hash = ?1 WHERE content_hash = ?2"),
                params![new, old],
            )?;
        }
        transaction.execute(
            "UPDATE tracks SET content_hash = ?1 WHERE content_hash = ?2",
            params![new, old],
        )?;
        transaction.execute(
            "UPDATE source_files SET content_hash = ?1 WHERE content_hash = ?2",
            params![new, old],
        )?;
        transaction.execute(
            "UPDATE blobs SET hash = ?1 WHERE hash = ?2",
            params![new, old],
        )?;
        transaction.execute(
            "UPDATE referenced_blobs SET hash = ?1 WHERE hash = ?2",
            params![new, old],
        )?;
        // Dropped rather than moved, so the caller's re-identification starts clean.
        transaction.execute(
            "DELETE FROM identification_results WHERE content_hash = ?1",
            [old],
        )?;

        transaction.commit()?;
        Ok(())
    }

    pub fn purge_blob(&self, hash: &str) -> Result<bool, StoreError> {
        validate_hash(hash)?;
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let blob_url = format!("/v1/blobs/{hash}");
        let references: u64 = transaction.query_row(
            r#"
            SELECT
                (SELECT COUNT(*) FROM tracks
                 WHERE content_hash = ?1 AND purged_at IS NULL)
              + (SELECT COUNT(*) FROM tracks
                 WHERE purged_at IS NULL AND (
                    json_extract(metadata, '$.artwork_hash') = ?1
                    OR json_extract(metadata, '$.artwork_url') = ?2
                    OR (json_extract(metadata, '$.manual_artwork_set') = 1
                        AND json_extract(metadata, '$.manual_artwork_hash') = ?1)
                 ))
              + (SELECT COUNT(*) FROM identification_results
                 WHERE artwork_url = ?2)
              + (SELECT COUNT(*) FROM transcoded_blobs WHERE blob_hash = ?1)
            "#,
            params![hash, blob_url],
            |row| row.get(0),
        )?;
        if references > 0 {
            return Err(StoreError::BlobReferenced);
        }
        let removed = match fs::remove_file(self.blob_path(hash)) {
            Ok(()) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => return Err(error.into()),
        };
        transaction.execute("DELETE FROM blobs WHERE hash = ?1", [hash])?;
        transaction.execute("DELETE FROM referenced_blobs WHERE hash = ?1", [hash])?;
        transaction.commit()?;
        Ok(removed)
    }

    /// Deletes the stored copy of a hash that nothing refers to any more.
    ///
    /// Blob files are addressed by content, so moving a track's identity with
    /// [`Self::rekey_content_hash`] renames the row but cannot move the file: the bytes
    /// stay where the old hash put them. Re-importing then writes the new bytes to their
    /// own path and the old file is left with nothing pointing at it — a second full copy
    /// of the track, per written track, invisible until the disk fills.
    ///
    /// Refuses while any row still references the hash, so this cannot delete something in
    /// use no matter what the caller believes.
    pub fn discard_orphaned_blob(&self, hash: &str) -> Result<bool, StoreError> {
        validate_hash(hash)?;
        let referenced: bool = self.connection.lock().query_row(
            "SELECT EXISTS(SELECT 1 FROM blobs WHERE hash = ?1) \
             OR EXISTS(SELECT 1 FROM tracks WHERE content_hash = ?1)",
            [hash],
            |row| row.get(0),
        )?;
        if referenced {
            return Ok(false);
        }
        let path = self.blob_path(hash);
        if !path.is_file() {
            return Ok(false);
        }
        fs::remove_file(&path)?;
        Ok(true)
    }

    fn blob_path(&self, hash: &str) -> PathBuf {
        let hash = hash.to_ascii_lowercase();
        self.root.join("blobs").join(&hash[..2]).join(hash)
    }

    fn upload_path(&self, hash: &str) -> PathBuf {
        self.root
            .join("uploads")
            .join(format!("{}.partial", hash.to_ascii_lowercase()))
    }

    fn referenced_blob_path(&self, hash: &str) -> Result<Option<PathBuf>, StoreError> {
        let path: Option<String> = self
            .connection
            .lock()
            .query_row(
                "SELECT path FROM referenced_blobs WHERE hash = ?1 AND available = 1",
                [hash],
                |row| row.get(0),
            )
            .optional()?;
        Ok(path.map(PathBuf::from).filter(|path| path.is_file()))
    }

    fn all_snapshot_tracks(&self) -> Result<Vec<ManifestEntry>, StoreError> {
        let mut tracks = Vec::new();
        loop {
            let page = self.snapshot_tracks(tracks.len() as u64, 1_000)?;
            let is_last = page.len() < 1_000;
            tracks.extend(page);
            if is_last {
                return Ok(tracks);
            }
        }
    }
}

fn migrate(connection: &Connection) -> Result<(), rusqlite::Error> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS operations (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            operation_id TEXT NOT NULL UNIQUE,
            device_id TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload TEXT NOT NULL,
            accepted_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS operations_cursor ON operations(sequence);
        CREATE TABLE IF NOT EXISTS device_credentials (
            device_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            device_type TEXT NOT NULL DEFAULT 'Device',
            credential_hash TEXT NOT NULL,
            paired_at TEXT NOT NULL,
            revoked_at TEXT,
            last_seen_at TEXT,
            last_synced_at TEXT,
            offline_track_count INTEGER,
            can_contribute INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS join_previews (
            preview_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            request TEXT NOT NULL,
            preview TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            consumed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS tracks (
            hub_track_id TEXT PRIMARY KEY,
            content_hash TEXT,
            metadata TEXT NOT NULL DEFAULT '{}',
            field_versions TEXT NOT NULL DEFAULT '{}',
            tombstoned_at INTEGER,
            purged_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS tracks_content_hash ON tracks(content_hash);
        CREATE TABLE IF NOT EXISTS listening_events (
            event_id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            started_at REAL,
            ended_at REAL,
            listened_seconds REAL NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS playback_activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            state TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            peer_address TEXT,
            payload TEXT NOT NULL,
            UNIQUE(session_id, device_id, revision)
        );
        CREATE INDEX IF NOT EXISTS playback_activity_events_observed
            ON playback_activity_events(observed_at);
        CREATE TABLE IF NOT EXISTS playback_activity_latest (
            session_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            state TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            peer_address TEXT,
            payload TEXT NOT NULL,
            PRIMARY KEY(session_id, device_id)
        );
        CREATE TABLE IF NOT EXISTS http_request_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            observed_at INTEGER NOT NULL,
            method TEXT NOT NULL,
            path TEXT NOT NULL,
            peer_address TEXT NOT NULL,
            status INTEGER NOT NULL,
            latency_micros INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS http_request_events_observed
            ON http_request_events(observed_at);
        CREATE TABLE IF NOT EXISTS loudness (
            content_hash TEXT NOT NULL,
            algorithm_version INTEGER NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY(content_hash, algorithm_version)
        );
        CREATE TABLE IF NOT EXISTS loudness_analysis_failures (
            content_hash TEXT NOT NULL,
            algorithm_version INTEGER NOT NULL,
            error TEXT NOT NULL,
            attempted_at INTEGER NOT NULL,
            PRIMARY KEY(content_hash, algorithm_version)
        );
        -- Engineered audio features (tempo, energy, brightness, dynamic range, MFCC/
        -- chroma vector — see `aro_track_id::audio_features`), local to this hub since
        -- only the hub itself ever analyzes (it always has direct file access to what
        -- it scans). Not CRDT-synced, unlike `loudness` above.
        CREATE TABLE IF NOT EXISTS audio_features (
            content_hash TEXT NOT NULL,
            algorithm_version INTEGER NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY(content_hash, algorithm_version)
        );
        CREATE TABLE IF NOT EXISTS audio_feature_failures (
            content_hash TEXT NOT NULL,
            algorithm_version INTEGER NOT NULL,
            error TEXT NOT NULL,
            attempted_at INTEGER NOT NULL,
            PRIMARY KEY(content_hash, algorithm_version)
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (13, unixepoch());
        CREATE TABLE IF NOT EXISTS blobs (
            hash TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            verified_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS referenced_blobs (
            hash TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            available INTEGER NOT NULL DEFAULT 1,
            verified_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sources (
            source_id TEXT PRIMARY KEY,
            mode TEXT NOT NULL CHECK(mode IN ('managed', 'referenced')),
            path TEXT,
            available INTEGER NOT NULL DEFAULT 1,
            warning TEXT,
            owner_device_id TEXT,
            name TEXT NOT NULL DEFAULT 'Music Folder',
            last_seen_at TEXT,
            last_scan_at TEXT,
            last_error TEXT,
            detached_at TEXT
        );
        CREATE TABLE IF NOT EXISTS source_files (
            source_id TEXT NOT NULL REFERENCES sources(source_id),
            relative_path TEXT NOT NULL,
            hub_track_id TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_millis INTEGER NOT NULL,
            available INTEGER NOT NULL DEFAULT 1,
            last_seen_at TEXT NOT NULL,
            PRIMARY KEY(source_id, relative_path)
        );
        CREATE INDEX IF NOT EXISTS source_files_track
            ON source_files(hub_track_id);
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (1, unixepoch());
        "#,
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS identification_cache (
            fingerprint TEXT PRIMARY KEY,
            acoustid_response TEXT,
            musicbrainz_response TEXT,
            created_at INTEGER NOT NULL,
            refreshed_at INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (5, unixepoch());
        "#,
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS identification_results (
            content_hash TEXT PRIMARY KEY,
            title TEXT,
            artist TEXT,
            album TEXT,
            artwork_url TEXT,
            musicbrainz_recording_id TEXT,
            acoustid_id TEXT,
            identified_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS identification_results_identified_at
            ON identification_results(identified_at);
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (6, unixepoch());
        "#,
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS release_group_affinity (
            artist_normalized TEXT NOT NULL,
            release_group_id TEXT NOT NULL,
            release_title TEXT,
            track_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(artist_normalized, release_group_id)
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (7, unixepoch());
        "#,
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS musicbrainz_release_cache (
            release_id TEXT PRIMARY KEY,
            response TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            refreshed_at INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (8, unixepoch());
        "#,
    )?;
    // `DEFAULT 0` is deliberate: every row written before this column existed lands below
    // any real `CACHE_SCHEMA_VERSION` and is therefore treated as stale on next access —
    // see `aro_track_id::queue`'s freshness check, which replaced an earlier one-off check
    // for a single specific missing field with this general mechanism.
    let _ = connection.execute(
        "ALTER TABLE identification_cache ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 0",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE listening_events ADD COLUMN started_at REAL",
        [],
    );
    let _ = connection.execute("ALTER TABLE listening_events ADD COLUMN ended_at REAL", []);
    let _ = connection.execute(
        "ALTER TABLE listening_events ADD COLUMN listened_seconds REAL NOT NULL DEFAULT 0",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE listening_events ADD COLUMN completed INTEGER NOT NULL DEFAULT 0",
        [],
    );
    // A real negative signal for Tier 1 behavioural playlists (Forgotten Favourites,
    // Deep Cuts) — see the client's `PlaybackController.startSong` skip-detection doc
    // comment. Synced via the same `listening_session` CRDT op as `completed`.
    let _ = connection.execute(
        "ALTER TABLE listening_events ADD COLUMN skipped INTEGER NOT NULL DEFAULT 0",
        [],
    );
    connection.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS listening_events_started
            ON listening_events(started_at);
        CREATE TABLE IF NOT EXISTS playback_activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            state TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            peer_address TEXT,
            payload TEXT NOT NULL,
            UNIQUE(session_id, device_id, revision)
        );
        CREATE INDEX IF NOT EXISTS playback_activity_events_observed
            ON playback_activity_events(observed_at);
        CREATE TABLE IF NOT EXISTS playback_activity_latest (
            session_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            state TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            peer_address TEXT,
            payload TEXT NOT NULL,
            PRIMARY KEY(session_id, device_id)
        );
        CREATE TABLE IF NOT EXISTS http_request_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            observed_at INTEGER NOT NULL,
            method TEXT NOT NULL,
            path TEXT NOT NULL,
            peer_address TEXT NOT NULL,
            status INTEGER NOT NULL,
            latency_micros INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS http_request_events_observed
            ON http_request_events(observed_at);
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (10, unixepoch());
        "#,
    )?;
    connection.execute(
        r#"
        UPDATE listening_events
        SET started_at = json_extract(payload, '$.started_at'),
            ended_at = json_extract(payload, '$.ended_at'),
            listened_seconds = COALESCE(json_extract(payload, '$.listened_seconds'), 0),
            completed = COALESCE(json_extract(payload, '$.completed'), 0)
        WHERE started_at IS NULL
        "#,
        [],
    )?;
    let _ = connection.execute(
        "ALTER TABLE device_credentials ADD COLUMN device_type TEXT NOT NULL DEFAULT 'Device'",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE device_credentials ADD COLUMN last_seen_at TEXT",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE device_credentials ADD COLUMN last_synced_at TEXT",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE device_credentials ADD COLUMN offline_track_count INTEGER",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE device_credentials ADD COLUMN can_contribute INTEGER NOT NULL DEFAULT 0",
        [],
    );
    let _ = connection.execute("ALTER TABLE sources ADD COLUMN owner_device_id TEXT", []);
    let _ = connection.execute(
        "ALTER TABLE sources ADD COLUMN name TEXT NOT NULL DEFAULT 'Music Folder'",
        [],
    );
    let _ = connection.execute("ALTER TABLE sources ADD COLUMN last_seen_at TEXT", []);
    let _ = connection.execute("ALTER TABLE sources ADD COLUMN last_scan_at TEXT", []);
    let _ = connection.execute("ALTER TABLE sources ADD COLUMN last_error TEXT", []);
    let _ = connection.execute("ALTER TABLE sources ADD COLUMN detached_at TEXT", []);
    // Provenance for how each identification result was produced, so a later reconcile
    // pass can tell "never revised" apart from "already a confident group match" and
    // decide whether a new answer is actually better evidence, not just different evidence
    // — see `aro_track_id::queue`'s revision rule. `resolution_generation` defaults to 0,
    // below any real `aro_track_id::IDENTIFICATION_GENERATION`, so every row written before
    // this column existed is eligible for exactly one reconcile pass at the current
    // generation, same `DEFAULT`-driven staleness pattern as `identification_cache
    // .schema_version`.
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN resolution_source TEXT",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN resolution_score REAL",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN resolution_generation INTEGER NOT NULL DEFAULT 0",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN release_id TEXT",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN release_group_id TEXT",
        [],
    );
    let _ = connection.execute(
        "CREATE INDEX IF NOT EXISTS identification_results_generation ON identification_results(resolution_generation)",
        [],
    );
    let _ = connection.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (9, unixepoch())",
        [],
    );
    // JSON-array-encoded genre/mood tags derived from MusicBrainz folksonomy data (see
    // `aro_track_id::musicbrainz::canonicalize_tags`), consumed client-side to drive
    // auto-generated mood/genre playlists. `NULL` for rows predating this column or
    // recordings with no matching MusicBrainz tag data.
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN musicbrainz_genres TEXT",
        [],
    );
    let _ = connection.execute(
        "ALTER TABLE identification_results ADD COLUMN mood_tags TEXT",
        [],
    );
    let _ = connection.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (10, unixepoch())",
        [],
    );
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS source_files (
            source_id TEXT NOT NULL REFERENCES sources(source_id),
            relative_path TEXT NOT NULL,
            hub_track_id TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_millis INTEGER NOT NULL,
            available INTEGER NOT NULL DEFAULT 1,
            last_seen_at TEXT NOT NULL,
            PRIMARY KEY(source_id, relative_path)
        );
        CREATE INDEX IF NOT EXISTS source_files_track
            ON source_files(hub_track_id);
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (4, unixepoch());
        "#,
    )?;
    connection.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (3, unixepoch())",
        [],
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS musicbrainz_recording_cache (
            recording_id TEXT PRIMARY KEY,
            response TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            refreshed_at INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (11, unixepoch());
        "#,
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS group_reconcile_attempts (
            folder TEXT PRIMARY KEY,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_attempted_at INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (12, unixepoch());
        "#,
    )?;
    // Affinity used to be a bare counter bumped on every identification, so re-running
    // identification inflated it without bound — a 355-track library had accumulated a
    // tally of 53,710 for one release group, which drowns out every genuine signal.
    // Recording which tracks voted makes the tally idempotent, and rebuilding it from
    // `identification_results` repairs libraries that already ran away.
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS release_group_affinity_members (
            artist_normalized TEXT NOT NULL,
            release_group_id TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            PRIMARY KEY(artist_normalized, release_group_id, content_hash)
        );
        "#,
    )?;
    // Unlike the `CREATE TABLE IF NOT EXISTS` batches above, these repairs rewrite data
    // and must run exactly once. Every statement in this function executes on every open,
    // so a data repair left unguarded would re-apply itself on each restart — harmless for
    // an idempotent recount, destructive for the deletion in migration 15.
    run_once(connection, 13, |connection| {
        connection.execute_batch(
            r#"
            INSERT OR IGNORE INTO release_group_affinity_members
                (artist_normalized, release_group_id, content_hash)
            SELECT affinity.artist_normalized, results.release_group_id, results.content_hash
            FROM identification_results AS results
            JOIN release_group_affinity AS affinity
                ON affinity.release_group_id = results.release_group_id
            WHERE results.release_group_id IS NOT NULL;
            UPDATE release_group_affinity SET track_count = (
                SELECT COUNT(*) FROM release_group_affinity_members AS members
                WHERE members.artist_normalized = release_group_affinity.artist_normalized
                  AND members.release_group_id = release_group_affinity.release_group_id
            );
            "#,
        )
    })?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS artwork_candidate_cache (
            cache_key TEXT PRIMARY KEY,
            response TEXT NOT NULL,
            refreshed_at INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (14, unixepoch());
        "#,
    )?;
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS transcoded_blobs (
            content_hash TEXT NOT NULL,
            quality TEXT NOT NULL,
            blob_hash TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(content_hash, quality)
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (16, unixepoch());
        "#,
    )?;
    // Votes cast before a track was re-identified were never withdrawn, so a track filed
    // wrongly and later corrected was counted for both albums at once — 23 of 407 votes in
    // one real library. Drop every vote that disagrees with what identification currently
    // says, then rebuild the tallies from what's left.
    run_once(connection, 15, |connection| {
        connection.execute_batch(
            r#"
            DELETE FROM release_group_affinity_members
            WHERE NOT EXISTS (
                SELECT 1 FROM identification_results AS results
                WHERE results.content_hash = release_group_affinity_members.content_hash
                  AND results.release_group_id = release_group_affinity_members.release_group_id
            );
            UPDATE release_group_affinity SET track_count = (
                SELECT COUNT(*) FROM release_group_affinity_members AS members
                WHERE members.artist_normalized = release_group_affinity.artist_normalized
                  AND members.release_group_id = release_group_affinity.release_group_id
            );
            DELETE FROM release_group_affinity WHERE track_count <= 0;
            "#,
        )
    })?;
    Ok(())
}

/// Runs a data repair the first time only, recording it in `schema_migrations`.
///
/// Every other statement in [`migrate`] is a `CREATE TABLE IF NOT EXISTS` or an equivalent
/// no-op on second running, so they can be issued unconditionally on every open. A repair
/// that rewrites or deletes rows cannot: re-running it would undo whatever the running
/// system has legitimately done since.
fn run_once(
    connection: &Connection,
    version: i64,
    apply: impl FnOnce(&Connection) -> Result<(), rusqlite::Error>,
) -> Result<(), rusqlite::Error> {
    let already_applied: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = ?1)",
        [version],
        |row| row.get(0),
    )?;
    if already_applied {
        return Ok(());
    }
    apply(connection)?;
    connection.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?1, unixepoch())",
        [version],
    )?;
    Ok(())
}

fn optional_timestamp(
    value: Option<String>,
) -> Result<Option<chrono::DateTime<chrono::Utc>>, rusqlite::Error> {
    value
        .map(|value| {
            chrono::DateTime::parse_from_rfc3339(&value)
                .map(|date| date.to_utc())
                .map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        value.len(),
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })
        })
        .transpose()
}

fn ratio(value: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        value as f64 / total as f64
    }
}

fn materialize_operation(
    transaction: &rusqlite::Transaction<'_>,
    operation: &Operation,
) -> Result<(), rusqlite::Error> {
    if operation.entity_type == "listening_session" {
        transaction.execute(
            r#"
            INSERT INTO listening_events
                (event_id, track_id, device_id, payload, started_at,
                 ended_at, listened_seconds, completed, skipped)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ON CONFLICT(event_id) DO UPDATE SET
                track_id = excluded.track_id,
                device_id = excluded.device_id,
                payload = excluded.payload,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                listened_seconds = excluded.listened_seconds,
                completed = excluded.completed,
                skipped = excluded.skipped
            "#,
            params![
                operation.entity_id,
                operation
                    .payload
                    .get("track_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                operation.device_id.to_string(),
                operation.payload.to_string(),
                operation.payload.get("started_at").and_then(Value::as_f64),
                operation.payload.get("ended_at").and_then(Value::as_f64),
                operation
                    .payload
                    .get("listened_seconds")
                    .and_then(Value::as_f64)
                    .unwrap_or_default(),
                operation
                    .payload
                    .get("completed")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                operation
                    .payload
                    .get("skipped")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            ],
        )?;
        return Ok(());
    }
    if operation.entity_type == "loudness" {
        let hash = operation
            .payload
            .get("content_hash")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let version = operation
            .payload
            .get("algorithm_version")
            .and_then(Value::as_i64)
            .unwrap_or_default();
        transaction.execute(
            r#"
            INSERT INTO loudness(content_hash, algorithm_version, payload)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(content_hash, algorithm_version)
            DO UPDATE SET payload = excluded.payload
            "#,
            params![hash, version, operation.payload.to_string()],
        )?;
        return Ok(());
    }
    if operation.entity_type != "track" && operation.entity_type != "track_state" {
        return Ok(());
    }
    let track_id = operation.entity_id.clone();
    if Uuid::parse_str(&track_id).is_err() {
        return Ok(());
    }
    let existing: Option<(String, String, Option<i64>)> = transaction
        .query_row(
            "SELECT metadata, field_versions, tombstoned_at FROM tracks WHERE hub_track_id = ?1",
            [&track_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let (mut metadata, mut versions, mut tombstoned_at) = existing
        .map(|(metadata, versions, tombstone)| {
            (
                serde_json::from_str::<serde_json::Map<String, Value>>(&metadata)
                    .unwrap_or_default(),
                serde_json::from_str::<BTreeMap<String, aro_sync_protocol::HybridTimestamp>>(
                    &versions,
                )
                .unwrap_or_default(),
                tombstone,
            )
        })
        .unwrap_or_default();
    if let Value::Object(values) = &operation.payload {
        for (field, value) in values {
            let Some(timestamp) = operation.field_versions.get(field) else {
                continue;
            };
            if versions
                .get(field)
                .is_none_or(|current| timestamp > current)
            {
                metadata.insert(field.clone(), value.clone());
                versions.insert(field.clone(), timestamp.clone());
            }
        }
    }
    match operation.kind.as_str() {
        "tombstone" | "delete" => tombstoned_at = Some(chrono::Utc::now().timestamp()),
        "restore" => tombstoned_at = None,
        _ => {}
    }
    let content_hash = metadata
        .get("content_hash")
        .and_then(Value::as_str)
        .map(str::to_owned);
    transaction.execute(
        r#"
        INSERT INTO tracks
            (hub_track_id, content_hash, metadata, field_versions, tombstoned_at)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(hub_track_id) DO UPDATE SET
            content_hash = excluded.content_hash,
            metadata = excluded.metadata,
            field_versions = excluded.field_versions,
            tombstoned_at = excluded.tombstoned_at
        "#,
        params![
            track_id,
            content_hash,
            Value::Object(metadata).to_string(),
            serde_json::to_string(&versions).expect("field versions serialize"),
            tombstoned_at,
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use uuid::Uuid;

    fn operation(id: Uuid) -> Operation {
        Operation {
            operation_id: id,
            device_id: Uuid::nil(),
            entity_type: "track".into(),
            entity_id: "one".into(),
            kind: "upsert".into(),
            payload: serde_json::json!({}),
            field_versions: Default::default(),
        }
    }

    #[test]
    fn operations_are_idempotent_and_cursor_pages_are_stable() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let op = operation(Uuid::new_v4());
        assert_eq!(
            store
                .append_operations(std::slice::from_ref(&op))
                .unwrap()
                .len(),
            1
        );
        assert_eq!(store.append_operations(&[op]).unwrap().len(), 1);
        assert_eq!(store.changes_after(0, 10).unwrap().len(), 1);
        assert!(store.changes_after(1, 10).unwrap().is_empty());
    }

    /// A push-only exchange sends `u64::MAX` to mean "return nothing to me".
    /// SQLite's INTEGER is signed, so binding that unsaturated fails the
    /// conversion and turns an ordinary sync into a 500 for every client.
    #[test]
    fn a_cursor_beyond_the_signed_range_returns_nothing_rather_than_failing() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        store
            .append_operations(&[operation(Uuid::new_v4())])
            .unwrap();
        assert!(store.changes_after(u64::MAX, 1).unwrap().is_empty());
        assert!(
            store
                .changes_after(i64::MAX as u64 + 1, 500)
                .unwrap()
                .is_empty()
        );
        // The ordinary cursor path must be untouched by the saturation.
        assert_eq!(store.changes_after(0, 10).unwrap().len(), 1);
    }

    /// The upload-only exchange asks for nothing with an explicit zero, which
    /// must mean "no changes" rather than falling through to a clamped page.
    #[test]
    fn a_zero_limit_returns_no_changes_rather_than_one() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        store
            .append_operations(&[operation(Uuid::new_v4())])
            .unwrap();
        assert!(store.changes_after(0, 0).unwrap().is_empty());
        assert_eq!(store.changes_after(0, 1).unwrap().len(), 1);
    }

    /// The offline count arrives straight off the wire and lands in the same
    /// signed column, so an absurd report must not fail the whole exchange.
    #[test]
    fn an_out_of_range_offline_track_count_is_saturated_not_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        store
            .record_device_seen(Uuid::new_v4(), true, Some(u64::MAX))
            .unwrap();
    }

    #[test]
    fn catalog_page_reads_lightweight_track_metadata_without_blobs() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let timestamp = aro_sync_protocol::HybridTimestamp {
            physical_millis: 1,
            logical: 0,
            device_id,
        };
        let mut field_versions = BTreeMap::new();
        for field in [
            "content_hash",
            "title",
            "artist",
            "album",
            "track_number",
            "codec",
            "sample_rate",
            "bit_depth",
            "channel_count",
            "bitrate",
            "artwork_url",
        ] {
            field_versions.insert(field.to_owned(), timestamp.clone());
        }
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: track_id.to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({
                    "content_hash": "a".repeat(64),
                    "title": "Test Song",
                    "artist": "Test Artist",
                    "album": "Test Album",
                    "track_number": 1,
                    "codec": "flac",
                    "sample_rate": 96_000,
                    "bit_depth": 24,
                    "channel_count": 2,
                    "bitrate": 2_304_000.0,
                    "artwork_url": format!("/v1/blobs/{}", "b".repeat(64)),
                }),
                field_versions,
            }])
            .unwrap();
        store
            .put_loudness_analysis(&"a".repeat(64), 2, -14.25, 0.91, device_id)
            .unwrap();

        let page = store
            .catalog_page(0, 10, Some("test song"), Some("artist"))
            .unwrap();
        assert_eq!(page.tracks.len(), 1);
        assert_eq!(page.tracks[0].track_id, track_id);
        assert_eq!(page.tracks[0].title, "Test Song");
        assert_eq!(page.tracks[0].codec.as_deref(), Some("flac"));
        assert_eq!(page.tracks[0].sample_rate, Some(96_000.0));
        assert_eq!(page.tracks[0].bit_depth, Some(24));
        assert_eq!(page.tracks[0].channel_count, Some(2));
        assert_eq!(page.tracks[0].bitrate, Some(2_304_000.0));
        assert_eq!(
            page.tracks[0].artwork_hash.as_deref(),
            Some("b".repeat(64).as_str())
        );
        assert_eq!(page.tracks[0].integrated_lufs, Some(-14.25));
        assert_eq!(page.tracks[0].peak_amplitude, Some(0.91));
        assert_eq!(page.tracks[0].loudness_algorithm_version, Some(2));
        assert!(page.tracks[0].loudness_analyzed_at.is_some());
        assert!(!page.tracks[0].available);
        assert!(page.tracks[0].byte_count.is_none());
    }

    #[test]
    fn interrupted_upload_resumes_and_corruption_never_publishes() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let content = b"complete audio";
        let hash = hex::encode(Sha256::digest(content));
        assert_eq!(store.write_chunk(&hash, 0, &content[..4]).unwrap(), 4);
        assert_eq!(store.blob_status(&hash).unwrap().2, 4);
        assert_eq!(
            store.write_chunk(&hash, 4, &content[4..]).unwrap(),
            content.len() as u64
        );
        store.commit_blob(&hash, content.len() as u64).unwrap();
        assert!(store.blob_status(&hash).unwrap().0);

        let corrupt_hash = "0".repeat(64);
        store.write_chunk(&corrupt_hash, 0, b"wrong").unwrap();
        assert!(store.commit_blob(&corrupt_hash, 5).is_err());
        assert!(!store.blob_status(&corrupt_hash).unwrap().0);
    }

    #[test]
    fn release_cache_round_trips_and_versions() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        assert!(store.release_cache_get("rel-1").unwrap().is_none());
        store
            .release_cache_put(
                "rel-1",
                &serde_json::json!({"id": "rel-1", "title": "1"}),
                2,
            )
            .unwrap();

        let entry = store.release_cache_get("rel-1").unwrap().unwrap();
        assert_eq!(
            entry.response,
            serde_json::json!({"id": "rel-1", "title": "1"})
        );
        assert_eq!(entry.schema_version, 2);

        // Upsert overwrites in place, same as identification_cache_put.
        store
            .release_cache_put(
                "rel-1",
                &serde_json::json!({"id": "rel-1", "title": "1 (2015)"}),
                3,
            )
            .unwrap();
        let updated = store.release_cache_get("rel-1").unwrap().unwrap();
        assert_eq!(updated.schema_version, 3);
        assert_eq!(
            updated.response,
            serde_json::json!({"id": "rel-1", "title": "1 (2015)"})
        );
    }

    #[test]
    fn folder_members_returns_only_available_files_in_the_exact_folder() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let source_root = directory.path().join("library");
        store
            .register_host_source(source_id, "Library", "managed", &source_root)
            .unwrap();

        // Two files in the target folder...
        store
            .upsert_source_file(
                source_id,
                "Beatles/1/01 Love Me Do.m4a",
                Uuid::new_v4(),
                "hash-1",
                100,
                0,
            )
            .unwrap();
        store
            .upsert_source_file(
                source_id,
                "Beatles/1/02 From Me To You.m4a",
                Uuid::new_v4(),
                "hash-2",
                100,
                0,
            )
            .unwrap();
        // ...one in a different folder...
        store
            .upsert_source_file(
                source_id,
                "Editors/The Back Room/01 Bones.m4a",
                Uuid::new_v4(),
                "hash-3",
                100,
                0,
            )
            .unwrap();
        // ...and one unavailable file in the target folder, which must be excluded.
        store
            .upsert_source_file(
                source_id,
                "Beatles/1/03 She Loves You.m4a",
                Uuid::new_v4(),
                "hash-4",
                100,
                0,
            )
            .unwrap();
        store
            .connection
            .lock()
            .execute(
                "UPDATE source_files SET available = 0 WHERE relative_path = 'Beatles/1/03 She Loves You.m4a'",
                [],
            )
            .unwrap();

        let members = store
            .folder_members(&source_root.join("Beatles").join("1"))
            .unwrap();

        let mut hashes: Vec<_> = members
            .iter()
            .map(|member| member.content_hash.clone())
            .collect();
        hashes.sort();
        assert_eq!(hashes, vec!["hash-1".to_string(), "hash-2".to_string()]);
    }

    #[test]
    fn identification_result_returns_a_single_result_by_content_hash() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        assert!(store.identification_result("hash-1").unwrap().is_none());
        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-1".into(),
                title: Some("December".into()),
                artist: Some("Neck Deep".into()),
                album: Some("Life's Not Out to Get You".into()),
                artwork_url: None,
                musicbrainz_recording_id: Some("rec-1".into()),
                acoustid_id: Some("ac-1".into()),
                identified_at: 1_000,
                resolution_source: None,
                resolution_score: None,
                resolution_generation: 0,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();

        let result = store.identification_result("hash-1").unwrap().unwrap();
        assert_eq!(result.title.as_deref(), Some("December"));
        assert_eq!(result.album.as_deref(), Some("Life's Not Out to Get You"));
    }

    fn result_with_release_and_artwork(
        content_hash: &str,
        release_id: Option<&str>,
        artwork_url: Option<&str>,
    ) -> IdentificationResult {
        result_with_release_group_and_artwork(content_hash, release_id, None, artwork_url)
    }

    fn result_with_release_group_and_artwork(
        content_hash: &str,
        release_id: Option<&str>,
        release_group_id: Option<&str>,
        artwork_url: Option<&str>,
    ) -> IdentificationResult {
        IdentificationResult {
            content_hash: content_hash.into(),
            title: Some("Title".into()),
            artist: None,
            album: None,
            artwork_url: artwork_url.map(Into::into),
            musicbrainz_recording_id: None,
            acoustid_id: None,
            identified_at: 1,
            resolution_source: Some("group".into()),
            resolution_score: None,
            resolution_generation: 0,
            release_id: release_id.map(Into::into),
            release_group_id: release_group_id.map(Into::into),
            musicbrainz_genres: None,
            mood_tags: None,
        }
    }

    #[test]
    fn identification_results_missing_artwork_excludes_unidentified_and_already_cached() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        // Identified with a release but no artwork yet -- the exact gap this backfills.
        // Also carries a release_group_id, since the caller needs it to fall back to the
        // release-group's cover art when the release's own has nothing archived.
        store
            .put_identification_result(&result_with_release_group_and_artwork(
                "missing",
                Some("release-1"),
                Some("group-1"),
                None,
            ))
            .unwrap();
        // Already has artwork -- nothing to do.
        store
            .put_identification_result(&result_with_release_and_artwork(
                "has-artwork",
                Some("release-2"),
                Some("/v1/blobs/abc"),
            ))
            .unwrap();
        // No release resolved at all -- not this backfill's job (that's `should_revise`'s
        // territory, a completely different kind of "not done yet").
        store
            .put_identification_result(&result_with_release_and_artwork("no-release", None, None))
            .unwrap();

        let missing = store.identification_results_missing_artwork(10).unwrap();
        assert_eq!(
            missing,
            vec![(
                "missing".to_string(),
                "release-1".to_string(),
                Some("group-1".to_string())
            )]
        );
    }

    #[test]
    fn set_artwork_url_does_not_overwrite_an_existing_value() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        store
            .put_identification_result(&result_with_release_and_artwork(
                "hash-1",
                Some("release-1"),
                None,
            ))
            .unwrap();

        store.set_artwork_url("hash-1", "/v1/blobs/first").unwrap();
        assert_eq!(
            store
                .identification_result("hash-1")
                .unwrap()
                .unwrap()
                .artwork_url
                .as_deref(),
            Some("/v1/blobs/first")
        );

        // A concurrent normal write already having set it wins -- backfill never stomps it.
        store.set_artwork_url("hash-1", "/v1/blobs/second").unwrap();
        assert_eq!(
            store
                .identification_result("hash-1")
                .unwrap()
                .unwrap()
                .artwork_url
                .as_deref(),
            Some("/v1/blobs/first")
        );
    }

    #[test]
    fn resolution_columns_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-1".into(),
                title: Some("December".into()),
                artist: Some("Neck Deep".into()),
                album: Some("Life's Not Out to Get You".into()),
                artwork_url: None,
                musicbrainz_recording_id: Some("rec-1".into()),
                acoustid_id: Some("ac-1".into()),
                identified_at: 1_000,
                resolution_source: Some("group".into()),
                resolution_score: Some(0.92),
                resolution_generation: 3,
                release_id: Some("release-1".into()),
                release_group_id: Some("rg-1".into()),
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();

        let result = store.identification_result("hash-1").unwrap().unwrap();
        assert_eq!(result.resolution_source.as_deref(), Some("group"));
        assert_eq!(result.resolution_score, Some(0.92));
        assert_eq!(result.resolution_generation, 3);
        assert_eq!(result.release_id.as_deref(), Some("release-1"));
        assert_eq!(result.release_group_id.as_deref(), Some("rg-1"));
    }

    #[test]
    fn identification_result_row_predating_resolution_columns_defaults_generation_to_zero() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        // Simulates a row written before these columns existed.
        store
            .connection
            .lock()
            .execute(
                r#"
                INSERT INTO identification_results
                    (content_hash, title, artist, album, artwork_url,
                     musicbrainz_recording_id, acoustid_id, identified_at)
                VALUES ('hash-legacy', 'Song', 'Artist', NULL, NULL, NULL, NULL, 1)
                "#,
                [],
            )
            .unwrap();

        let result = store.identification_result("hash-legacy").unwrap().unwrap();
        assert_eq!(result.resolution_generation, 0);
        assert!(result.resolution_source.is_none());
        assert!(result.resolution_score.is_none());
    }

    #[test]
    fn folders_needing_reconcile_orders_by_member_count() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let source_root = directory.path().join("library");
        store
            .register_host_source(source_id, "Library", "managed", &source_root)
            .unwrap();

        let seed = |relative_path: &str, hash: &str, generation: i64| {
            store
                .upsert_source_file(source_id, relative_path, Uuid::new_v4(), hash, 100, 0)
                .unwrap();
            store
                .put_identification_result(&IdentificationResult {
                    content_hash: hash.into(),
                    title: Some("Title".into()),
                    artist: None,
                    album: None,
                    artwork_url: None,
                    musicbrainz_recording_id: None,
                    acoustid_id: None,
                    identified_at: 1,
                    resolution_source: Some("per_file".into()),
                    resolution_score: None,
                    resolution_generation: generation,
                    release_id: None,
                    release_group_id: None,
                    musicbrainz_genres: None,
                    mood_tags: None,
                })
                .unwrap();
        };

        // "Big" (3 members) and "Small" (1 member) both predate the current generation (0
        // < 1); "Current" (2 members) is already at generation 1 and must not appear.
        seed("Small/a.m4a", "s1", 0);
        seed("Big/a.m4a", "b1", 0);
        seed("Big/b.m4a", "b2", 0);
        seed("Big/c.m4a", "b3", 0);
        seed("Current/a.m4a", "c1", 1);
        seed("Current/b.m4a", "c2", 1);

        let folders = store.folders_needing_reconcile(1, 10).unwrap();

        assert_eq!(folders.len(), 2);
        assert_eq!(folders[0], source_root.join("Big"));
        assert_eq!(folders[1], source_root.join("Small"));
    }

    #[test]
    fn folders_needing_reconcile_respects_the_limit() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let source_root = directory.path().join("library");
        store
            .register_host_source(source_id, "Library", "managed", &source_root)
            .unwrap();

        for folder in ["A", "B", "C", "D"] {
            store
                .upsert_source_file(
                    source_id,
                    &format!("{folder}/a.m4a"),
                    Uuid::new_v4(),
                    folder,
                    100,
                    0,
                )
                .unwrap();
            store
                .put_identification_result(&IdentificationResult {
                    content_hash: folder.into(),
                    title: Some("Title".into()),
                    artist: None,
                    album: None,
                    artwork_url: None,
                    musicbrainz_recording_id: None,
                    acoustid_id: None,
                    identified_at: 1,
                    resolution_source: None,
                    resolution_score: None,
                    resolution_generation: 0,
                    release_id: None,
                    release_group_id: None,
                    musicbrainz_genres: None,
                    mood_tags: None,
                })
                .unwrap();
        }

        let folders = store.folders_needing_reconcile(1, 2).unwrap();
        assert_eq!(folders.len(), 2);
    }

    /// Proves the reconcile sweep's termination guarantee directly at the store layer,
    /// without needing the network-dependent `identify_group` path: touching every visited
    /// file's generation (exactly what `aro_track_id::queue::reconcile_sweep` does after
    /// processing a folder, regardless of whether `should_revise` actually rewrote
    /// anything) removes that folder from `folders_needing_reconcile`'s result set for the
    /// current generation — so a sweep can never see the same folder twice.
    #[test]
    fn touching_generation_removes_the_folder_from_future_reconcile_batches() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let source_root = directory.path().join("library");
        store
            .register_host_source(source_id, "Library", "managed", &source_root)
            .unwrap();
        store
            .upsert_source_file(
                source_id,
                "Neck Deep/a.m4a",
                Uuid::new_v4(),
                "hash-1",
                100,
                0,
            )
            .unwrap();
        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-1".into(),
                title: Some("December".into()),
                artist: None,
                album: None,
                artwork_url: None,
                musicbrainz_recording_id: None,
                acoustid_id: None,
                identified_at: 1,
                resolution_source: Some("per_file".into()),
                resolution_score: None,
                resolution_generation: 0,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();

        assert_eq!(store.folders_needing_reconcile(1, 10).unwrap().len(), 1);

        store.touch_identification_generation("hash-1", 1).unwrap();

        assert!(store.folders_needing_reconcile(1, 10).unwrap().is_empty());
    }

    #[test]
    fn recording_cache_round_trips_and_versions() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        assert!(store.recording_cache_get("rec-1").unwrap().is_none());
        store
            .recording_cache_put(
                "rec-1",
                &serde_json::json!({"id": "rec-1", "title": "Hey Jude"}),
                2,
            )
            .unwrap();

        let entry = store.recording_cache_get("rec-1").unwrap().unwrap();
        assert_eq!(
            entry.response,
            serde_json::json!({"id": "rec-1", "title": "Hey Jude"})
        );
        assert_eq!(entry.schema_version, 2);

        store
            .recording_cache_put(
                "rec-1",
                &serde_json::json!({"id": "rec-1", "title": "Hey Jude!"}),
                3,
            )
            .unwrap();
        let updated = store.recording_cache_get("rec-1").unwrap().unwrap();
        assert_eq!(updated.schema_version, 3);
        assert_eq!(
            updated.response,
            serde_json::json!({"id": "rec-1", "title": "Hey Jude!"})
        );
    }

    #[test]
    fn record_group_reconcile_attempt_increments_and_persists() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let folder = Path::new("/library/The Beatles/1");

        assert_eq!(store.record_group_reconcile_attempt(folder).unwrap(), 1);
        assert_eq!(store.record_group_reconcile_attempt(folder).unwrap(), 2);
        assert_eq!(store.record_group_reconcile_attempt(folder).unwrap(), 3);
    }

    fn seed_folder_result(
        store: &HubStore,
        source_id: Uuid,
        relative_path: &str,
        hash: &str,
        resolution_source: Option<&str>,
    ) {
        store
            .upsert_source_file(source_id, relative_path, Uuid::new_v4(), hash, 100, 0)
            .unwrap();
        store
            .put_identification_result(&IdentificationResult {
                content_hash: hash.into(),
                title: Some("Title".into()),
                artist: None,
                album: None,
                artwork_url: None,
                musicbrainz_recording_id: None,
                acoustid_id: None,
                identified_at: 1,
                resolution_source: resolution_source.map(Into::into),
                resolution_score: None,
                resolution_generation: 1,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();
    }

    #[test]
    fn folders_needing_group_retry_selects_only_fully_rejected_multi_member_folders() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let source_root = directory.path().join("library");
        store
            .register_host_source(source_id, "Library", "managed", &source_root)
            .unwrap();

        // "Rejected": 3 members, every one fell back to per_file -- a group match was
        // attempted and lost outright. Must be selected.
        seed_folder_result(&store, source_id, "Rejected/a.m4a", "r1", Some("per_file"));
        seed_folder_result(&store, source_id, "Rejected/b.m4a", "r2", Some("per_file"));
        seed_folder_result(&store, source_id, "Rejected/c.m4a", "r3", Some("per_file"));

        // "MostlyAccepted": 3 members, 2 group-sourced and 1 genuine per-file outlier (a
        // bonus track) -- not a rejected group, must not be selected.
        seed_folder_result(
            &store,
            source_id,
            "MostlyAccepted/a.m4a",
            "m1",
            Some("group"),
        );
        seed_folder_result(
            &store,
            source_id,
            "MostlyAccepted/b.m4a",
            "m2",
            Some("group"),
        );
        seed_folder_result(
            &store,
            source_id,
            "MostlyAccepted/c.m4a",
            "m3",
            Some("per_file"),
        );

        // "TooSmall": below the group-matching minimum, never eligible in the first place.
        seed_folder_result(&store, source_id, "TooSmall/a.m4a", "t1", Some("per_file"));

        let folders = store.folders_needing_group_retry(2, 8, 10).unwrap();

        assert_eq!(folders, vec![source_root.join("Rejected")]);
    }

    #[test]
    fn folders_needing_group_retry_excludes_folders_past_the_attempt_cap() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let source_root = directory.path().join("library");
        store
            .register_host_source(source_id, "Library", "managed", &source_root)
            .unwrap();
        seed_folder_result(&store, source_id, "Rejected/a.m4a", "r1", Some("per_file"));
        seed_folder_result(&store, source_id, "Rejected/b.m4a", "r2", Some("per_file"));

        assert_eq!(
            store.folders_needing_group_retry(2, 2, 10).unwrap(),
            vec![source_root.join("Rejected")]
        );

        store
            .record_group_reconcile_attempt(&source_root.join("Rejected"))
            .unwrap();
        assert_eq!(
            store.folders_needing_group_retry(2, 2, 10).unwrap(),
            vec![source_root.join("Rejected")]
        );

        store
            .record_group_reconcile_attempt(&source_root.join("Rejected"))
            .unwrap();
        assert!(
            store
                .folders_needing_group_retry(2, 2, 10)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn touch_identification_generation_never_regresses_an_already_advanced_row() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-1".into(),
                title: Some("Title".into()),
                artist: None,
                album: None,
                artwork_url: None,
                musicbrainz_recording_id: None,
                acoustid_id: None,
                identified_at: 1,
                resolution_source: Some("group".into()),
                resolution_score: Some(0.9),
                resolution_generation: 5,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();

        // A lower/equal generation must never move the marker backwards.
        store.touch_identification_generation("hash-1", 2).unwrap();
        assert_eq!(
            store
                .identification_result("hash-1")
                .unwrap()
                .unwrap()
                .resolution_generation,
            5
        );

        store.touch_identification_generation("hash-1", 7).unwrap();
        assert_eq!(
            store
                .identification_result("hash-1")
                .unwrap()
                .unwrap()
                .resolution_generation,
            7
        );
    }

    #[test]
    fn identification_cache_row_predating_schema_version_column_defaults_to_zero() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        // Simulates a row written before this column existed: every other column but
        // `schema_version`, which the migration's `DEFAULT 0` must supply on its own.
        store
            .connection
            .lock()
            .execute(
                r#"
                INSERT INTO identification_cache
                    (fingerprint, acoustid_response, musicbrainz_response, created_at, refreshed_at)
                VALUES ('fp-legacy', '{"status":"ok"}', '{"id":"mb-1"}', 1, 1)
                "#,
                [],
            )
            .unwrap();

        let entry = store
            .identification_cache_get("fp-legacy")
            .unwrap()
            .unwrap();
        assert_eq!(entry.schema_version, 0);
    }

    #[test]
    fn migration_is_repeatable() {
        let directory = tempfile::tempdir().unwrap();
        HubStore::open(directory.path()).unwrap();
        HubStore::open(directory.path()).unwrap();
    }

    #[test]
    fn migration_upgrades_legacy_listening_events_before_indexing_it() {
        let directory = tempfile::tempdir().unwrap();
        let connection = Connection::open(directory.path().join("hub.sqlite3")).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE listening_events (
                    event_id TEXT PRIMARY KEY,
                    track_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    payload TEXT NOT NULL
                );
                "#,
            )
            .unwrap();
        drop(connection);

        let store = HubStore::open(directory.path()).unwrap();
        let connection = store.connection.lock();
        connection
            .execute(
                "INSERT INTO listening_events (event_id, track_id, device_id, payload)
                 VALUES ('legacy-event', 'track', 'device', '{}')",
                [],
            )
            .unwrap();
        let defaults: (Option<f64>, Option<f64>, f64, i64) = connection
            .query_row(
                "SELECT started_at, ended_at, listened_seconds, completed
                 FROM listening_events WHERE event_id = 'legacy-event'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(defaults, (None, None, 0.0, 0));
        let index_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                 WHERE type = 'index' AND name = 'listening_events_started'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(index_count, 1);
    }

    #[test]
    fn device_authorization_and_revocation_survive_restart() {
        let directory = tempfile::tempdir().unwrap();
        let device = DeviceSummary {
            device_id: Uuid::new_v4(),
            name: "Mac".into(),
            device_type: "Mac".into(),
            paired_at: chrono::Utc::now(),
            revoked_at: None,
            last_seen_at: None,
            last_synced_at: None,
            offline_track_count: None,
            can_contribute: false,
        };
        HubStore::open(directory.path())
            .unwrap()
            .save_device(&device, "credential")
            .unwrap();

        let reopened = HubStore::open(directory.path()).unwrap();
        assert!(
            reopened
                .authorize_device(device.device_id, "credential")
                .unwrap()
        );
        assert!(
            !reopened
                .authorize_device(device.device_id, "wrong")
                .unwrap()
        );
        assert!(reopened.revoke_device(device.device_id).unwrap());
        assert!(
            !reopened
                .authorize_device(device.device_id, "credential")
                .unwrap()
        );
    }

    #[test]
    fn contribution_permissions_and_library_mode_are_independent() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let device_id = Uuid::new_v4();
        let device = DeviceSummary {
            device_id,
            name: "Contributor".into(),
            device_type: "Mac".into(),
            paired_at: chrono::Utc::now(),
            revoked_at: None,
            last_seen_at: None,
            last_synced_at: None,
            offline_track_count: None,
            can_contribute: false,
        };
        store.save_device(&device, "credential").unwrap();
        assert!(!store.device_can_contribute(device_id).unwrap());
        assert!(store.set_device_contribution(device_id, true).unwrap());
        assert!(store.device_can_contribute(device_id).unwrap());

        let linked = directory.path().join("linked");
        std::fs::create_dir_all(&linked).unwrap();
        store
            .register_host_source(Uuid::new_v4(), "Linked", "referenced", &linked)
            .unwrap();
        assert!(!store.library_accepts_contributions().unwrap());

        let stored = directory.path().join("stored");
        std::fs::create_dir_all(&stored).unwrap();
        store
            .register_host_source(Uuid::new_v4(), "Stored", "managed", &stored)
            .unwrap();
        assert!(store.library_accepts_contributions().unwrap());
    }

    #[test]
    fn export_manifest_keeps_recently_removed_bit_exact_tracks() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("original.flac");
        std::fs::write(&source, b"exact original bytes").unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let (hash, size) = store.import_managed(&source).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let version = HybridTimestamp {
            physical_millis: chrono::Utc::now().timestamp_millis(),
            logical: 0,
            device_id,
        };
        let fields = [
            "content_hash",
            "byte_count",
            "title",
            "artist",
            "album",
            "original_filename",
            "original_extension",
        ]
        .into_iter()
        .map(|field| (field.to_owned(), version.clone()))
        .collect();
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: track_id.to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({
                    "content_hash": hash,
                    "byte_count": size,
                    "title": "Exact",
                    "artist": "Artist",
                    "album": "Album",
                    "original_filename": "original.flac",
                    "original_extension": "flac"
                }),
                field_versions: fields,
            }])
            .unwrap();
        let active = store.export_manifest("Library").unwrap();
        assert_eq!(active.tracks.len(), 1);
        assert_eq!(active.tracks[0].byte_count, size);
        assert_eq!(active.tracks[0].original_extension, "flac");
        assert!(active.tracks[0].removed_at.is_none());

        assert!(store.tombstone_by_hash(&hash, device_id).unwrap());
        let removed = store.export_manifest("Library").unwrap();
        assert_eq!(removed.tracks.len(), 1);
        assert!(removed.tracks[0].removed_at.is_some());
        assert_eq!(
            std::fs::read(store.blob_path_for_download(&hash).unwrap().unwrap()).unwrap(),
            b"exact original bytes"
        );
    }

    #[test]
    fn track_fields_materialize_and_tombstones_restore() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let timestamp = aro_sync_protocol::HybridTimestamp {
            physical_millis: 100,
            logical: 0,
            device_id,
        };
        let upsert = Operation {
            operation_id: Uuid::new_v4(),
            device_id,
            entity_type: "track".into(),
            entity_id: track_id.to_string(),
            kind: "upsert".into(),
            payload: serde_json::json!({
                "content_hash": "a".repeat(64),
                "title": "Track"
            }),
            field_versions: BTreeMap::from([
                ("content_hash".into(), timestamp.clone()),
                ("title".into(), timestamp),
            ]),
        };
        store.append_operations(&[upsert]).unwrap();
        let snapshot = store.snapshot_tracks(0, 10).unwrap();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].content_hash, Some("a".repeat(64)));
        assert!(!snapshot[0].tombstoned);

        for kind in ["tombstone", "restore"] {
            store
                .append_operations(&[Operation {
                    operation_id: Uuid::new_v4(),
                    device_id,
                    entity_type: "track_state".into(),
                    entity_id: track_id.to_string(),
                    kind: kind.into(),
                    payload: serde_json::json!({}),
                    field_versions: BTreeMap::new(),
                }])
                .unwrap();
        }
        assert!(!store.snapshot_tracks(0, 10).unwrap()[0].tombstoned);
    }

    #[test]
    fn manual_metadata_remains_golden_until_explicit_reset() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let version = |millis| aro_sync_protocol::HybridTimestamp {
            physical_millis: millis,
            logical: 0,
            device_id,
        };
        let operation = |payload: Value, fields: &[&str], millis| Operation {
            operation_id: Uuid::new_v4(),
            device_id,
            entity_type: if millis == 1 { "track" } else { "track_state" }.into(),
            entity_id: track_id.to_string(),
            kind: "upsert".into(),
            payload,
            field_versions: fields
                .iter()
                .map(|field| ((*field).to_owned(), version(millis)))
                .collect(),
        };
        store
            .append_operations(&[operation(
                serde_json::json!({
                    "content_hash": "b".repeat(64),
                    "title": "Scanned",
                    "artist": "Scanned Artist"
                }),
                &["content_hash", "title", "artist"],
                1,
            )])
            .unwrap();
        store
            .append_operations(&[operation(
                serde_json::json!({
                    "manual_title": "Chosen",
                    "manual_title_set": true
                }),
                &["manual_title", "manual_title_set"],
                2,
            )])
            .unwrap();
        store
            .append_operations(&[operation(
                serde_json::json!({"title": "Later Identification"}),
                &["title"],
                3,
            )])
            .unwrap();
        assert_eq!(
            store.catalog_page(0, 10, None, None).unwrap().tracks[0].title,
            "Chosen"
        );

        store
            .append_operations(&[operation(
                serde_json::json!({"manual_title_set": false}),
                &["manual_title_set"],
                4,
            )])
            .unwrap();
        assert_eq!(
            store.catalog_page(0, 10, None, None).unwrap().tracks[0].title,
            "Later Identification"
        );
    }

    #[test]
    fn manual_artwork_is_imported_and_replicated_by_hash() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let timestamp = HybridTimestamp {
            physical_millis: 1,
            logical: 0,
            device_id,
        };
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: track_id.to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({
                    "content_hash": "c".repeat(64),
                    "title": "Track"
                }),
                field_versions: BTreeMap::from([
                    ("content_hash".into(), timestamp.clone()),
                    ("title".into(), timestamp.clone()),
                ]),
            }])
            .unwrap();

        let artwork = b"manual cover bytes";
        let expected_hash = hex::encode(Sha256::digest(artwork));
        let accepted = store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track_state".into(),
                entity_id: track_id.to_string(),
                kind: "set_metadata".into(),
                payload: serde_json::json!({
                    "manual_artwork_set": true,
                    "manual_artwork_base64": BASE64.encode(artwork)
                }),
                field_versions: BTreeMap::from([
                    ("manual_artwork_set".into(), timestamp.clone()),
                    ("manual_artwork_base64".into(), timestamp),
                ]),
            }])
            .unwrap();

        assert_eq!(
            store.catalog_page(0, 10, None, None).unwrap().tracks[0]
                .artwork_hash
                .as_deref(),
            Some(expected_hash.as_str())
        );
        assert_eq!(
            fs::read(
                store
                    .blob_path_for_download(&expected_hash)
                    .unwrap()
                    .unwrap()
            )
            .unwrap(),
            artwork
        );
        let payload = accepted[0].operation.payload.as_object().unwrap();
        assert!(!payload.contains_key("manual_artwork_base64"));
        assert_eq!(
            payload.get("manual_artwork_hash").and_then(Value::as_str),
            Some(expected_hash.as_str())
        );
    }

    #[test]
    fn managed_and_referenced_imports_are_verified() {
        let directory = tempfile::tempdir().unwrap();
        let source_directory = tempfile::tempdir().unwrap();
        let managed = source_directory.path().join("managed.flac");
        let referenced = source_directory.path().join("referenced.flac");
        fs::write(&managed, b"managed audio").unwrap();
        fs::write(&referenced, b"referenced audio").unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        let (managed_hash, managed_size) = store.import_managed(&managed).unwrap();
        let (referenced_hash, referenced_size) = store.import_referenced(&referenced).unwrap();
        assert_eq!(managed_size, 13);
        assert_eq!(referenced_size, 16);
        assert!(store.blob_status(&managed_hash).unwrap().0);
        assert!(store.blob_status(&referenced_hash).unwrap().0);
        assert!(
            store
                .blob_path_for_download(&referenced_hash)
                .unwrap()
                .is_some()
        );
        let managed_blob = store.blob_path(&managed_hash);
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            assert_ne!(
                managed.metadata().unwrap().ino(),
                managed_blob.metadata().unwrap().ino(),
                "Managed imports must be independent copies, never hard links"
            );
            assert_eq!(managed_blob.metadata().unwrap().nlink(), 1);
        }
        fs::write(&managed, b"source changed later").unwrap();
        assert_eq!(fs::read(managed_blob).unwrap(), b"managed audio");

        fs::write(&referenced, b"changed").unwrap();
        assert!(
            store
                .blob_path_for_download(&referenced_hash)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn join_preview_detects_conflicts_and_commit_is_single_use() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let hub_device = Uuid::new_v4();
        let client_device = Uuid::new_v4();
        let track_id = Uuid::new_v4();
        let hash = "b".repeat(64);
        let hub_timestamp = HybridTimestamp {
            physical_millis: 100,
            logical: 0,
            device_id: hub_device,
        };
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id: hub_device,
                entity_type: "track".into(),
                entity_id: track_id.to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({
                    "content_hash": hash,
                    "title": "Hub title"
                }),
                field_versions: BTreeMap::from([
                    ("content_hash".into(), hub_timestamp.clone()),
                    ("title".into(), hub_timestamp),
                ]),
            }])
            .unwrap();
        let local_timestamp = HybridTimestamp {
            physical_millis: 50,
            logical: 0,
            device_id: client_device,
        };
        let join = JoinPreviewRequest {
            device_id: client_device,
            manifest: vec![ManifestEntry {
                local_track_id: "local-1".into(),
                hub_track_id: None,
                content_hash: Some("b".repeat(64)),
                fields: BTreeMap::from([(
                    "title".into(),
                    VersionedValue {
                        value: Value::String("Local title".into()),
                        timestamp: local_timestamp,
                    },
                )]),
                tombstoned: false,
            }],
        };
        let preview = store.create_join_preview(&join).unwrap();
        assert_eq!(preview.deduplicated_tracks, 1);
        assert_eq!(preview.conflicts.len(), 1);
        let key = format!(
            "{}:{}",
            preview.conflicts[0].track_id, preview.conflicts[0].field
        );
        let commit = JoinCommitRequest {
            preview_id: preview.preview_id,
            resolutions: BTreeMap::from([(key, ConflictChoice::Local)]),
        };
        store.commit_join(client_device, &commit).unwrap();
        let snapshot = store.snapshot_tracks(0, 10).unwrap();
        assert_eq!(
            snapshot[0].fields["title"].value,
            Value::String("Local title".into())
        );
        assert!(matches!(
            store.commit_join(client_device, &commit),
            Err(StoreError::JoinPreviewNotFound)
        ));
    }

    #[test]
    fn identification_cache_round_trips_and_track_metadata_is_readable() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let device_id = Uuid::new_v4();
        let track_id = Uuid::new_v4();

        assert!(store.identification_cache_get("fp-1").unwrap().is_none());
        store
            .identification_cache_put(
                "fp-1",
                Some(&serde_json::json!({"status": "ok"})),
                Some(&serde_json::json!({"id": "mb-1"})),
                3,
            )
            .unwrap();
        let entry = store.identification_cache_get("fp-1").unwrap().unwrap();
        assert_eq!(
            entry.acoustid_response,
            Some(serde_json::json!({"status": "ok"}))
        );
        assert_eq!(
            entry.musicbrainz_response,
            Some(serde_json::json!({"id": "mb-1"}))
        );
        assert_eq!(entry.schema_version, 3);

        assert!(store.track_metadata(track_id).unwrap().is_none());
        let timestamp = HybridTimestamp {
            physical_millis: 1,
            logical: 0,
            device_id,
        };
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: track_id.to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({"title": "Song"}),
                field_versions: BTreeMap::from([("title".into(), timestamp)]),
            }])
            .unwrap();
        let metadata = store.track_metadata(track_id).unwrap().unwrap();
        assert_eq!(metadata.get("title"), Some(&Value::String("Song".into())));

        // No source_files row exists for this track, so it isn't reachable on disk.
        assert!(store.live_path_for_track(track_id).unwrap().is_none());
    }

    /// A referenced original is marked unavailable when a download fails to verify, but
    /// nothing restored it: re-import only runs when size or mtime changes, so a file that
    /// failed once for a transient reason stayed unavailable while sitting on disk. The
    /// scan is the only thing that actually looks, so its verdict has to propagate.
    #[test]
    fn a_scan_restores_a_referenced_file_that_came_back() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source_id = Uuid::new_v4();
        let hash = "e".repeat(64);
        {
            let connection = store.connection.lock();
            connection
                .execute(
                    "INSERT INTO sources(source_id, mode, path, available, name) \
                     VALUES (?1, 'referenced', '/music', 1, 'Music')",
                    params![source_id.to_string()],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO source_files(source_id, relative_path, hub_track_id, \
                     content_hash, size, modified_millis, available, last_seen_at) \
                     VALUES (?1, 'a.flac', ?2, ?3, 1, 1, 1, 'now')",
                    params![source_id.to_string(), Uuid::new_v4().to_string(), hash],
                )
                .unwrap();
            // Marked unavailable by a failed verify, exactly as `blob_path_for_download` does.
            connection
                .execute(
                    "INSERT INTO referenced_blobs(hash, path, size, available, verified_at) \
                     VALUES (?1, '/music/a.flac', 1, 0, 1)",
                    [&hash],
                )
                .unwrap();
        }

        let seen = HashSet::from(["a.flac".to_string()]);
        store.finish_source_scan(source_id, &seen, None).unwrap();

        let available: i64 = store
            .connection
            .lock()
            .query_row(
                "SELECT available FROM referenced_blobs WHERE hash = ?1",
                [&hash],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            available, 1,
            "a file the scan found should be available again"
        );

        // And a scan that no longer sees it marks it gone.
        store
            .finish_source_scan(source_id, &HashSet::new(), None)
            .unwrap();
        let available: i64 = store
            .connection
            .lock()
            .query_row(
                "SELECT available FROM referenced_blobs WHERE hash = ?1",
                [&hash],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            available, 0,
            "a file the scan no longer sees is unavailable"
        );
    }

    /// Writing corrected tags into a file changes its bytes, and therefore the SHA-256 that
    /// identifies the track everywhere. This asserts every hash-keyed table actually moved
    /// — by re-querying each one, not by counting — because a migration that misses a table
    /// leaves the track playable while silently losing its history or its analysis, which
    /// is the failure this function exists to prevent.
    #[test]
    /// A sweep exists to fill gaps. Re-asking AcoustID about tracks it has already
    /// answered for spends a rate-limited budget on settled questions, so identified
    /// tracks are skipped unless the caller explicitly asks for them.
    #[test]
    fn a_sweep_skips_tracks_that_have_already_been_identified() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let identified = "a".repeat(64);
        let unknown = "b".repeat(64);
        {
            let connection = store.connection.lock();
            for (hash, artist) in [(&identified, "Grimes"), (&unknown, "Grimes")] {
                connection
                    .execute(
                        "INSERT INTO tracks(hub_track_id, content_hash, metadata, field_versions) \
                         VALUES (?1, ?2, ?3, '{}')",
                        params![
                            Uuid::new_v4().to_string(),
                            hash,
                            serde_json::json!({"artist": artist}).to_string()
                        ],
                    )
                    .unwrap();
            }
            connection
                .execute(
                    "INSERT INTO identification_results(content_hash, title, identified_at) \
                     VALUES (?1, 'Oblivion', unixepoch())",
                    params![identified],
                )
                .unwrap();
        }

        let gaps = store.identification_scope(None, None, false).unwrap();
        assert_eq!(
            gaps.iter()
                .map(|(hash, _)| hash.clone())
                .collect::<Vec<_>>(),
            vec![unknown.clone()],
            "an already-identified track must not be queued again"
        );

        let everything = store.identification_scope(None, None, true).unwrap();
        assert_eq!(everything.len(), 2, "asking for all should mean all");

        // Scoping is what makes artist- and album-level syncs possible without the client
        // enumerating the catalogue, so an unmatched scope must return nothing rather than
        // quietly falling back to the whole library.
        assert!(
            store
                .identification_scope(Some("Someone Else"), None, true)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store
                .identification_scope(Some("grimes"), None, true)
                .unwrap()
                .len(),
            2,
            "artist matching is case-insensitive, as it is everywhere else"
        );
    }

    #[test]
    fn rekeying_a_content_hash_moves_every_table_that_identifies_a_track() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let old = "a".repeat(64);
        let new = "b".repeat(64);
        let device_id = Uuid::new_v4();
        let source_id = Uuid::new_v4();
        let track_id = Uuid::new_v4();

        {
            let connection = store.connection.lock();
            connection
                .execute(
                    "INSERT INTO tracks(hub_track_id, content_hash, metadata, field_versions) \
                     VALUES (?1, ?2, '{}', '{}')",
                    params![track_id.to_string(), old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO sources(source_id, mode, path, available, name) \
                     VALUES (?1, 'managed', '/music', 1, 'Music')",
                    params![source_id.to_string()],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO source_files(source_id, relative_path, hub_track_id, \
                     content_hash, size, modified_millis, last_seen_at) \
                     VALUES (?1, 'a.flac', ?2, ?3, 1, 1, 'now')",
                    params![source_id.to_string(), track_id.to_string(), old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO blobs(hash, size, verified_at) VALUES (?1, 1, 1)",
                    [&old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO loudness(content_hash, algorithm_version, payload) \
                     VALUES (?1, 1, '{}')",
                    [&old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO audio_features(content_hash, algorithm_version, payload) \
                     VALUES (?1, 1, '{}')",
                    [&old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO release_group_affinity_members\
                     (artist_normalized, release_group_id, content_hash) \
                     VALUES ('artist', 'rg', ?1)",
                    [&old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO transcoded_blobs\
                     (content_hash, quality, blob_hash, byte_count, created_at) \
                     VALUES (?1, 'saver', 'blob', 10, 1)",
                    [&old],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO identification_results(content_hash, identified_at) \
                     VALUES (?1, 1)",
                    [&old],
                )
                .unwrap();
            let _ = device_id;
        }

        store.rekey_content_hash(&old, &new).unwrap();

        let connection = store.connection.lock();
        let count = |sql: &str, hash: &str| -> i64 {
            connection.query_row(sql, [hash], |row| row.get(0)).unwrap()
        };

        // The audio itself is unchanged by a tag edit, so analysis and derived data follow
        // the file rather than being thrown away and recomputed.
        for (table, column) in [
            ("tracks", "content_hash"),
            ("source_files", "content_hash"),
            ("loudness", "content_hash"),
            ("audio_features", "content_hash"),
            ("release_group_affinity_members", "content_hash"),
            ("transcoded_blobs", "content_hash"),
            ("blobs", "hash"),
        ] {
            assert_eq!(
                count(
                    &format!("SELECT COUNT(*) FROM {table} WHERE {column} = ?1"),
                    &new
                ),
                1,
                "{table} should have moved to the new hash"
            );
            assert_eq!(
                count(
                    &format!("SELECT COUNT(*) FROM {table} WHERE {column} = ?1"),
                    &old
                ),
                0,
                "{table} should have nothing left under the old hash"
            );
        }

        // Identification is dropped rather than moved: the caller re-identifies, and a
        // stale answer keyed to bytes that no longer exist would be worse than none.
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM identification_results WHERE content_hash = ?1",
                &old
            ),
            0
        );
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM identification_results WHERE content_hash = ?1",
                &new
            ),
            0
        );
    }

    /// Writing tags changes a track's hash, and blob files are addressed by content — so
    /// the rekey renames the row while the pre-edit bytes stay at the old path. Nothing
    /// then refers to them, and on a managed hub that is a second full copy of the track
    /// for every write, invisible until the disk fills.
    #[test]
    fn the_superseded_copy_of_a_rewritten_track_is_reclaimed() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let old = "c".repeat(64);
        let stale = store.blob_path(&old);
        std::fs::create_dir_all(stale.parent().unwrap()).unwrap();
        std::fs::write(&stale, b"the bytes from before the edit").unwrap();

        // While anything still points at the hash it must survive, whatever the caller
        // believes -- deleting audio a track still refers to loses the track.
        {
            let connection = store.connection.lock();
            connection
                .execute(
                    "INSERT INTO tracks(hub_track_id, content_hash, metadata, field_versions) \
                     VALUES (?1, ?2, '{}', '{}')",
                    params![Uuid::new_v4().to_string(), old],
                )
                .unwrap();
        }
        assert!(!store.discard_orphaned_blob(&old).unwrap());
        assert!(stale.is_file(), "a referenced blob must never be deleted");

        {
            let connection = store.connection.lock();
            connection
                .execute("DELETE FROM tracks WHERE content_hash = ?1", params![old])
                .unwrap();
        }
        assert!(store.discard_orphaned_blob(&old).unwrap());
        assert!(!stale.exists(), "the superseded copy should be reclaimed");
        assert!(
            !store.discard_orphaned_blob(&old).unwrap(),
            "reclaiming twice is not an error"
        );
    }

    /// Rekeying onto a hash that already has rows must not collide. The file's current
    /// bytes are the truth; a leftover row from a previous life of that hash is not.
    #[test]
    fn rekeying_onto_an_occupied_hash_replaces_the_stale_rows() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let old = "c".repeat(64);
        let new = "d".repeat(64);
        {
            let connection = store.connection.lock();
            for (hash, version) in [(&old, 1), (&new, 2)] {
                connection
                    .execute(
                        "INSERT INTO loudness(content_hash, algorithm_version, payload) \
                         VALUES (?1, ?2, '{}')",
                        params![hash, version],
                    )
                    .unwrap();
            }
        }

        store.rekey_content_hash(&old, &new).unwrap();

        let connection = store.connection.lock();
        let version: i64 = connection
            .query_row(
                "SELECT algorithm_version FROM loudness WHERE content_hash = ?1",
                [&new],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(version, 1, "the migrated row should win over the stale one");
        let rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM loudness", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rows, 1, "no duplicate should survive");
    }

    /// Codec names alone get this wrong, and did: the reference library stores its codec
    /// as `m4a`, a *container* that holds lossless ALAC or lossy AAC. A name-only list
    /// reported a 300-track ALAC library as 0% lossless.
    #[test]
    fn lossless_detection_reads_the_evidence_not_just_the_container() {
        let metadata = |depth: Option<f64>, rate: f64, bitrate: f64| {
            let mut map = serde_json::Map::new();
            if let Some(depth) = depth {
                map.insert("bit_depth".into(), Value::from(depth));
            }
            map.insert("sample_rate".into(), Value::from(rate));
            map.insert("bitrate".into(), Value::from(bitrate));
            map
        };

        // ALAC in an m4a container: 1,012 kbps against 1,411 kbps uncompressed.
        assert!(is_lossless(
            "m4a",
            &metadata(Some(16.0), 44_100.0, 1_012_000.0)
        ));
        // AAC in the same container, at a bitrate no lossless encoder could produce.
        assert!(!is_lossless(
            "m4a",
            &metadata(Some(16.0), 44_100.0, 256_000.0)
        ));
        // Named formats never need the heuristic.
        assert!(is_lossless("flac", &serde_json::Map::new()));
        assert!(!is_lossless("mp3", &metadata(None, 44_100.0, 320_000.0)));
        // Nothing to judge by: claim nothing rather than overstate fidelity.
        assert!(!is_lossless("m4a", &serde_json::Map::new()));
    }

    /// Engagement is aggregated in three layers — heartbeats to sessions, sessions to
    /// fractions, fractions to a per-track summary — and an aggregate applied at the wrong
    /// layer silently collapses the whole library into one row rather than failing. It did
    /// exactly that when first written, so this asserts several tracks survive with
    /// distinct results, not merely that the query runs.
    #[test]
    fn engagement_is_summarised_per_track_and_records_abandonment() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let device_id = Uuid::new_v4();

        // Two sessions of a track played through, and two of another left a fifth of the
        // way in — the distinction a play count cannot make.
        let sessions: [(&str, &str, f64, f64, bool); 4] = [
            ("finished", "session-a", 180.0, 180.0, true),
            ("finished", "session-b", 179.0, 180.0, false),
            ("abandoned", "session-c", 40.0, 200.0, false),
            ("abandoned", "session-d", 38.0, 200.0, false),
        ];
        {
            let connection = store.connection.lock();
            for (hash, session, position, duration, completed) in sessions {
                let payload = serde_json::json!({
                    "content_hash": hash,
                    "position_seconds": position,
                    "duration_seconds": duration,
                    "completed": completed,
                })
                .to_string();
                connection
                    .execute(
                        "INSERT INTO playback_activity_events \
                         (session_id, revision, device_id, track_id, state, observed_at, payload) \
                         VALUES (?1, 1, ?2, ?3, 'playing', 1000, ?4)",
                        params![
                            session,
                            device_id.to_string(),
                            Uuid::new_v4().to_string(),
                            payload
                        ],
                    )
                    .unwrap();
            }
        }

        let seeds = store.playlist_seeds().unwrap();
        assert_eq!(
            seeds.engagement.len(),
            2,
            "each track must keep its own summary, got {:?}",
            seeds.engagement.keys().collect::<Vec<_>>()
        );

        let finished = &seeds.engagement["finished"];
        assert_eq!(finished.sessions, 2);
        assert_eq!(finished.completed_sessions, 2);
        assert_eq!(finished.abandoned_sessions, 0);
        assert_eq!(finished.completion_rate(), Some(1.0));

        let abandoned = &seeds.engagement["abandoned"];
        assert_eq!(abandoned.sessions, 2);
        assert_eq!(abandoned.completed_sessions, 0);
        assert_eq!(abandoned.abandoned_sessions, 2);
        assert!(
            abandoned.mean_fraction < 0.25,
            "expected a low mean fraction, got {}",
            abandoned.mean_fraction
        );

        // One session is not a rate: a single abandoned play is not evidence of dislike.
        assert_eq!(EngagementSummary::default().completion_rate(), None);
    }

    /// The whole point of planning a conversion is telling someone how long it will take,
    /// and that number is derived from track durations. Reading the wrong metadata key
    /// returns NULL rather than failing, which quotes every conversion as instant — so the
    /// duration actually has to be asserted, not just the track count.
    #[test]
    fn pending_transcodes_carry_real_durations_for_the_estimate() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let device_id = Uuid::new_v4();
        let timestamp = HybridTimestamp {
            physical_millis: 1,
            logical: 0,
            device_id,
        };
        let mut field_versions = BTreeMap::new();
        for field in ["content_hash", "title", "duration"] {
            field_versions.insert(field.to_owned(), timestamp.clone());
        }
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: Uuid::new_v4().to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({
                    "content_hash": "abc123",
                    "title": "Song",
                    "duration": 202.773,
                }),
                field_versions,
            }])
            .unwrap();

        let pending = store.tracks_missing_transcode("saver").unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].0, "abc123");
        assert!(
            (pending[0].1 - 202.773).abs() < 0.001,
            "duration must survive into the estimate, got {}",
            pending[0].1
        );

        // Once an encode exists the track drops out, so a second run doesn't re-quote work
        // already paid for.
        store
            .record_transcoded_blob("abc123", "saver", "blob-hash", 1_000)
            .unwrap();
        assert!(store.tracks_missing_transcode("saver").unwrap().is_empty());
        assert_eq!(store.tracks_missing_transcode("minimum").unwrap().len(), 1);
    }

    /// A generated encode is real work — minutes of CPU on a slow hub — and lives in the
    /// blob store like any other blob. Nothing points at it from `tracks`, so before
    /// `transcoded_blobs` was counted as a reference an ordinary purge treated it as an
    /// orphan and deleted it.
    #[test]
    fn a_cached_transcode_is_not_mistaken_for_an_orphan_blob() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let source = directory.path().join("encoded.opus");
        std::fs::write(&source, b"pretend this is ogg opus").unwrap();
        let (blob_hash, _size) = store.import_managed(&source).unwrap();

        // Unreferenced by anything, it is fair game.
        assert!(store.purge_blob(&blob_hash).unwrap());

        let (blob_hash, size) = store.import_managed(&source).unwrap();
        store
            .record_transcoded_blob("track-hash", "saver", &blob_hash, size)
            .unwrap();
        assert!(
            matches!(
                store.purge_blob(&blob_hash),
                Err(StoreError::BlobReferenced)
            ),
            "a cached transcode must not be purgeable as an orphan"
        );
    }

    /// Moving back up the quality ladder should be able to reclaim the space, but only the
    /// qualities being abandoned — never the one still in use.
    #[test]
    fn cleanup_removes_other_qualities_and_keeps_the_chosen_one() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        for (index, quality) in ["saver", "minimum", "balanced"].iter().enumerate() {
            let source = directory.path().join(format!("{quality}.opus"));
            // Distinct bytes per quality, so each gets its own blob rather than deduping
            // into one and confusing what "freed" means.
            std::fs::write(&source, format!("encoded audio {index}").as_bytes()).unwrap();
            let (blob_hash, size) = store.import_managed(&source).unwrap();
            store
                .record_transcoded_blob("track-hash", quality, &blob_hash, size)
                .unwrap();
        }
        assert_eq!(store.transcode_usage().unwrap().len(), 3);

        let (removed, freed) = store.purge_transcodes_except("saver").unwrap();
        assert_eq!(removed, 2);
        assert!(
            freed > 0,
            "freeing two encodes should report bytes reclaimed"
        );

        let remaining = store.transcode_usage().unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].0, "saver");
        assert!(
            store
                .transcoded_blob("track-hash", "saver")
                .unwrap()
                .is_some(),
            "the kept quality must still resolve"
        );
        assert!(
            store
                .transcoded_blob("track-hash", "minimum")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn release_group_affinity_tallies_survive_restart_and_are_scoped_per_artist() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        assert!(
            store
                .release_group_affinity("neck deep")
                .unwrap()
                .is_empty()
        );

        store
            .record_release_group_choice(
                "neck deep",
                "rg-real-album",
                Some("Life's Not Out to Get You"),
                "hash-track-one",
            )
            .unwrap();
        store
            .record_release_group_choice(
                "neck deep",
                "rg-real-album",
                Some("Life's Not Out to Get You"),
                "hash-track-two",
            )
            .unwrap();
        store
            .record_release_group_choice("the beatles", "rg-one", Some("1"), "hash-beatles-one")
            .unwrap();

        let neck_deep = store.release_group_affinity("neck deep").unwrap();
        assert_eq!(neck_deep.get("rg-real-album"), Some(&2));
        assert_eq!(neck_deep.len(), 1);

        // Re-identifying a track already counted must not inflate the tally: affinity
        // measures how much of the artist's music sits on the release, not how many
        // times identification has run over it.
        for _ in 0..5 {
            store
                .record_release_group_choice(
                    "neck deep",
                    "rg-real-album",
                    Some("Life's Not Out to Get You"),
                    "hash-track-one",
                )
                .unwrap();
        }
        assert_eq!(
            store
                .release_group_affinity("neck deep")
                .unwrap()
                .get("rg-real-album"),
            Some(&2)
        );

        // Re-identifying a track onto a *different* album must move its vote, not add a
        // second one. A track counted for both the album it was wrongly filed under and
        // the one it was corrected to keeps propping up the mistake on every later import.
        store
            .record_release_group_choice(
                "neck deep",
                "rg-corrected-album",
                Some("The Peace and the Panic"),
                "hash-track-two",
            )
            .unwrap();
        let moved = store.release_group_affinity("neck deep").unwrap();
        assert_eq!(moved.get("rg-real-album"), Some(&1));
        assert_eq!(moved.get("rg-corrected-album"), Some(&1));

        // And a group nothing points at any more should stop being an affinity signal
        // entirely rather than lingering at zero.
        store
            .record_release_group_choice(
                "neck deep",
                "rg-corrected-album",
                Some("The Peace and the Panic"),
                "hash-track-one",
            )
            .unwrap();
        let emptied = store.release_group_affinity("neck deep").unwrap();
        assert_eq!(emptied.get("rg-real-album"), None);
        assert_eq!(emptied.get("rg-corrected-album"), Some(&2));

        // Scoped per artist: the Beatles tally never shows up for Neck Deep and
        // vice versa.
        let beatles = store.release_group_affinity("the beatles").unwrap();
        assert_eq!(beatles.get("rg-one"), Some(&1));

        drop(store);
        let reopened = HubStore::open(directory.path()).unwrap();
        assert_eq!(
            reopened
                .release_group_affinity("neck deep")
                .unwrap()
                .get("rg-corrected-album"),
            Some(&2)
        );
    }

    #[test]
    fn identification_results_are_keyed_by_content_hash_and_pullable_since_a_cursor() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();

        assert!(!store.has_identification_result("hash-a").unwrap());
        assert!(
            store
                .identification_results_since(0, 10)
                .unwrap()
                .is_empty()
        );

        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-a".into(),
                title: Some("Song A".into()),
                artist: Some("Artist A".into()),
                album: None,
                artwork_url: None,
                musicbrainz_recording_id: Some("mb-a".into()),
                acoustid_id: Some("ac-a".into()),
                identified_at: 100,
                resolution_source: None,
                resolution_score: None,
                resolution_generation: 0,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();
        assert!(store.has_identification_result("hash-a").unwrap());

        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-b".into(),
                title: Some("Song B".into()),
                artist: None,
                album: None,
                artwork_url: None,
                musicbrainz_recording_id: None,
                acoustid_id: Some("ac-b".into()),
                identified_at: 200,
                resolution_source: None,
                resolution_score: None,
                resolution_generation: 0,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();

        let all = store.identification_results_since(0, 10).unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].content_hash, "hash-a");
        assert_eq!(all[1].content_hash, "hash-b");

        let since_a = store.identification_results_since(100, 10).unwrap();
        assert_eq!(since_a.len(), 1);
        assert_eq!(since_a[0].content_hash, "hash-b");

        // Re-identifying the same hash updates in place rather than duplicating.
        store
            .put_identification_result(&IdentificationResult {
                content_hash: "hash-a".into(),
                title: Some("Song A (corrected)".into()),
                artist: Some("Artist A".into()),
                album: Some("Album A".into()),
                artwork_url: None,
                musicbrainz_recording_id: Some("mb-a".into()),
                acoustid_id: Some("ac-a".into()),
                identified_at: 300,
                resolution_source: None,
                resolution_score: None,
                resolution_generation: 0,
                release_id: None,
                release_group_id: None,
                musicbrainz_genres: None,
                mood_tags: None,
            })
            .unwrap();
        let all = store.identification_results_since(0, 10).unwrap();
        assert_eq!(all.len(), 2);
        let updated = all.iter().find(|r| r.content_hash == "hash-a").unwrap();
        assert_eq!(updated.title.as_deref(), Some("Song A (corrected)"));
        assert_eq!(updated.album.as_deref(), Some("Album A"));
    }

    #[test]
    fn playback_activity_is_revisioned_without_fabricating_listening_history() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let hash = "a".repeat(64);
        let timestamp = HybridTimestamp {
            physical_millis: 100,
            logical: 0,
            device_id,
        };
        store
            .append_operations(&[Operation {
                operation_id: Uuid::new_v4(),
                device_id,
                entity_type: "track".into(),
                entity_id: track_id.to_string(),
                kind: "upsert".into(),
                payload: serde_json::json!({
                    "content_hash": hash,
                    "title": "Dashboard Track",
                    "artist": "Aro",
                    "duration": 120.0,
                    "codec": "flac",
                }),
                field_versions: BTreeMap::from([
                    ("content_hash".into(), timestamp.clone()),
                    ("title".into(), timestamp.clone()),
                    ("artist".into(), timestamp.clone()),
                    ("duration".into(), timestamp.clone()),
                    ("codec".into(), timestamp),
                ]),
            }])
            .unwrap();
        let started = chrono::Utc::now() - chrono::Duration::seconds(60);
        let session_id = Uuid::new_v4();
        let snapshot = PlaybackActivitySnapshot {
            session_id,
            revision: 1,
            content_hash: "a".repeat(64),
            state: PlaybackActivityState::Playing,
            position_seconds: 30.0,
            duration_seconds: Some(120.0),
            buffered_fraction: Some(0.75),
            observed_at: chrono::Utc::now(),
            started_at: started,
            completed: false,
            output: None,
        };
        assert!(
            store
                .record_playback_activity(device_id, &snapshot, Some("127.0.0.1:1"))
                .unwrap()
        );
        assert!(
            !store
                .record_playback_activity(device_id, &snapshot, None)
                .unwrap()
        );
        let stopped = PlaybackActivitySnapshot {
            revision: 2,
            state: PlaybackActivityState::Stopped,
            position_seconds: 60.0,
            observed_at: chrono::Utc::now(),
            completed: true,
            ..snapshot
        };
        assert!(
            store
                .record_playback_activity(device_id, &stopped, None)
                .unwrap()
        );
        let stats = store.dashboard_stats().unwrap();
        assert_eq!(stats["listening"]["logged_plays"], 0);
        assert_eq!(stats["library"]["track_count"], 1);
        assert_eq!(stats["library"]["formats"][0]["name"], "FLAC");
        assert!(store.dashboard_live_activity().unwrap().is_empty());
    }
}
