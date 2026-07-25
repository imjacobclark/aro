use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sonora_sync_core::{BlobError, hash_file, validate_hash, verify_file};
use sonora_sync_protocol::{
    ConflictChoice, DeviceSummary, FieldConflict, HybridTimestamp, JoinCommitRequest, JoinPreview,
    JoinPreviewRequest, ManifestEntry, Operation, SequencedOperation, VersionedValue,
};
use std::collections::{BTreeMap, HashSet};
use std::{
    fs::{self, OpenOptions},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::Arc,
};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

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
            let versions: BTreeMap<String, sonora_sync_protocol::HybridTimestamp> =
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
                (device_id, name, credential_hash, paired_at, revoked_at)
            VALUES (?1, ?2, ?3, ?4, NULL)
            ON CONFLICT(device_id) DO UPDATE SET
                name = excluded.name,
                credential_hash = excluded.credential_hash,
                paired_at = excluded.paired_at,
                revoked_at = NULL
            "#,
            params![
                summary.device_id.to_string(),
                summary.name,
                hash,
                summary.paired_at.to_rfc3339(),
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

    pub fn devices(&self) -> Result<Vec<DeviceSummary>, StoreError> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            "SELECT device_id, name, paired_at, revoked_at FROM device_credentials ORDER BY paired_at",
        )?;
        let devices = statement.query_map([], |row| {
            let id: String = row.get(0)?;
            let paired_at: String = row.get(2)?;
            let revoked_at: Option<String> = row.get(3)?;
            Ok(DeviceSummary {
                device_id: Uuid::parse_str(&id).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        id.len(),
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?,
                name: row.get(1)?,
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
            })
        })?;
        devices.collect::<Result<_, _>>().map_err(Into::into)
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
        if fs::hard_link(source, &upload).is_err() {
            fs::copy(source, &upload)?;
        }
        self.commit_blob(&hash, size)?;
        Ok((hash, size))
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
            credential_hash TEXT NOT NULL,
            paired_at TEXT NOT NULL,
            revoked_at TEXT
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
            warning TEXT
        );
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (1, unixepoch());
        "#,
    )
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
                serde_json::from_str::<BTreeMap<String, sonora_sync_protocol::HybridTimestamp>>(
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
            paired_at: chrono::Utc::now(),
            revoked_at: None,
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
    fn track_fields_materialize_and_tombstones_restore() {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        let track_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let timestamp = sonora_sync_protocol::HybridTimestamp {
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
}
