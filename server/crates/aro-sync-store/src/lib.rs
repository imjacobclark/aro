use aro_sync_core::{BlobError, hash_file, validate_hash, verify_file};
use aro_sync_protocol::{
    ConflictChoice, DeviceSummary, ExportManifest, ExportTrack, FieldConflict, HybridTimestamp,
    JoinCommitRequest, JoinPreview, JoinPreviewRequest, ManifestEntry, Operation,
    SequencedOperation, SourceHealthReport, VersionedValue,
};
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

/// One scanned, available file within a folder, as returned by [`HubStore::folder_members`].
#[derive(Clone, Debug)]
pub struct FolderMember {
    pub path: PathBuf,
    pub content_hash: String,
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
}

#[derive(Clone)]
pub struct HubStore {
    connection: Arc<Mutex<Connection>>,
    root: Arc<PathBuf>,
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
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let mut accepted = Vec::new();
        for operation in operations {
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

    pub fn changes_after(
        &self,
        after_sequence: u64,
        limit: u32,
    ) -> Result<Vec<SequencedOperation>, StoreError> {
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
            let text = |key: &str| metadata.get(key).and_then(Value::as_str).map(str::to_owned);
            let integer = |key: &str| {
                metadata
                    .get(key)
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
            SELECT source_id, name, mode, available, warning
            FROM sources
            ORDER BY name, source_id
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
                })
            })?
            .collect::<Result<_, _>>()?)
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
                       release_id, release_group_id
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
                 release_id, release_group_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
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
                release_group_id = excluded.release_group_id
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
            ],
        )?;
        Ok(())
    }

    /// Results identified after `after` (exclusive), oldest first — the pull side of
    /// the bridge the macOS app polls to merge results into its own local library
    /// catalog, since content hash (not any track id) is the only shared key.
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
                   release_id, release_group_id
            FROM identification_results
            WHERE identified_at > ?1
            ORDER BY identified_at
            LIMIT ?2
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

    /// Records that `artist_normalized`'s track identification resolved to
    /// `release_group_id` this time, incrementing its running tally. Used by
    /// `aro-track-id`'s "Intelligent" album-matching mode to let a release-group
    /// that already has several of an artist's tracks pull in the rest, instead of
    /// each track picking independently. Never overwrites `release_title` with
    /// `None` — later calls for the same release-group may not always have a title
    /// on hand, but earlier ones did.
    pub fn record_release_group_choice(
        &self,
        artist_normalized: &str,
        release_group_id: &str,
        release_title: Option<&str>,
    ) -> Result<(), StoreError> {
        self.connection.lock().execute(
            r#"
            INSERT INTO release_group_affinity(artist_normalized, release_group_id, release_title, track_count)
            VALUES (?1, ?2, ?3, 1)
            ON CONFLICT(artist_normalized, release_group_id) DO UPDATE SET
                release_title = COALESCE(excluded.release_title, release_group_affinity.release_title),
                track_count = release_group_affinity.track_count + 1
            "#,
            params![artist_normalized, release_group_id, release_title],
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

    pub fn purge_blob(&self, hash: &str) -> Result<bool, StoreError> {
        validate_hash(hash)?;
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        let references: u64 = transaction.query_row(
            "SELECT COUNT(*) FROM tracks WHERE content_hash = ?1 AND purged_at IS NULL",
            [hash],
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
            payload TEXT NOT NULL
        );
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

fn materialize_operation(
    transaction: &rusqlite::Transaction<'_>,
    operation: &Operation,
) -> Result<(), rusqlite::Error> {
    if operation.entity_type == "listening_session" {
        transaction.execute(
            r#"
            INSERT OR IGNORE INTO listening_events
                (event_id, track_id, device_id, payload)
            VALUES (?1, ?2, ?3, ?4)
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
            .release_cache_put("rel-1", &serde_json::json!({"id": "rel-1", "title": "1"}), 2)
            .unwrap();

        let entry = store.release_cache_get("rel-1").unwrap().unwrap();
        assert_eq!(entry.response, serde_json::json!({"id": "rel-1", "title": "1"}));
        assert_eq!(entry.schema_version, 2);

        // Upsert overwrites in place, same as identification_cache_put.
        store
            .release_cache_put("rel-1", &serde_json::json!({"id": "rel-1", "title": "1 (2015)"}), 3)
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
            .upsert_source_file(source_id, "Beatles/1/01 Love Me Do.m4a", Uuid::new_v4(), "hash-1", 100, 0)
            .unwrap();
        store
            .upsert_source_file(source_id, "Beatles/1/02 From Me To You.m4a", Uuid::new_v4(), "hash-2", 100, 0)
            .unwrap();
        // ...one in a different folder...
        store
            .upsert_source_file(source_id, "Editors/The Back Room/01 Bones.m4a", Uuid::new_v4(), "hash-3", 100, 0)
            .unwrap();
        // ...and one unavailable file in the target folder, which must be excluded.
        store
            .upsert_source_file(source_id, "Beatles/1/03 She Loves You.m4a", Uuid::new_v4(), "hash-4", 100, 0)
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

        let mut hashes: Vec<_> = members.iter().map(|member| member.content_hash.clone()).collect();
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
            })
            .unwrap();

        let result = store.identification_result("hash-1").unwrap().unwrap();
        assert_eq!(result.title.as_deref(), Some("December"));
        assert_eq!(result.album.as_deref(), Some("Life's Not Out to Get You"));
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
                .upsert_source_file(source_id, &format!("{folder}/a.m4a"), Uuid::new_v4(), folder, 100, 0)
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
            .upsert_source_file(source_id, "Neck Deep/a.m4a", Uuid::new_v4(), "hash-1", 100, 0)
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
            })
            .unwrap();

        assert_eq!(store.folders_needing_reconcile(1, 10).unwrap().len(), 1);

        store.touch_identification_generation("hash-1", 1).unwrap();

        assert!(store.folders_needing_reconcile(1, 10).unwrap().is_empty());
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
            })
            .unwrap();

        // A lower/equal generation must never move the marker backwards.
        store.touch_identification_generation("hash-1", 2).unwrap();
        assert_eq!(
            store.identification_result("hash-1").unwrap().unwrap().resolution_generation,
            5
        );

        store.touch_identification_generation("hash-1", 7).unwrap();
        assert_eq!(
            store.identification_result("hash-1").unwrap().unwrap().resolution_generation,
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
            )
            .unwrap();
        store
            .record_release_group_choice(
                "neck deep",
                "rg-real-album",
                Some("Life's Not Out to Get You"),
            )
            .unwrap();
        store
            .record_release_group_choice("the beatles", "rg-one", Some("1"))
            .unwrap();

        let neck_deep = store.release_group_affinity("neck deep").unwrap();
        assert_eq!(neck_deep.get("rg-real-album"), Some(&2));
        assert_eq!(neck_deep.len(), 1);

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
                .get("rg-real-album"),
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
            })
            .unwrap();
        let all = store.identification_results_since(0, 10).unwrap();
        assert_eq!(all.len(), 2);
        let updated = all.iter().find(|r| r.content_hash == "hash-a").unwrap();
        assert_eq!(updated.title.as_deref(), Some("Song A (corrected)"));
        assert_eq!(updated.album.as_deref(), Some("Album A"));
    }
}
