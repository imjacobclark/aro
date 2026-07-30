use crate::config::StorageMode;
use anyhow::{Context, Result, bail};
use aro_sync_protocol::{HybridTimestamp, Operation};
use aro_sync_store::{HubStore, SourceFolder};
use aro_track_id::{
    IdentificationQueue,
    loudness::{ALGORITHM_VERSION, LoudnessQueue},
};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use parking_lot::Mutex;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, UNIX_EPOCH},
};
use tokio::sync::mpsc;
use uuid::Uuid;

#[derive(Clone)]
pub struct SourceManager {
    inner: Arc<Inner>,
}

struct Inner {
    store: HubStore,
    hub_id: Uuid,
    mode: StorageMode,
    watcher: Mutex<RecommendedWatcher>,
    scan_lock: Mutex<()>,
    identification: IdentificationQueue,
    loudness: LoudnessQueue,
}

impl SourceManager {
    pub fn start(
        store: HubStore,
        hub_id: Uuid,
        mode: StorageMode,
        rescan_seconds: u64,
        identification: IdentificationQueue,
        loudness: LoudnessQueue,
    ) -> Result<Self> {
        let (events, mut receiver) = mpsc::unbounded_channel::<PathBuf>();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if let Ok(event) = event {
                for path in event.paths {
                    let _ = events.send(path);
                }
            }
        })?;
        let manager = Self {
            inner: Arc::new(Inner {
                store,
                hub_id,
                mode,
                watcher: Mutex::new(watcher),
                scan_lock: Mutex::new(()),
                identification,
                loudness,
            }),
        };
        for source in manager.list()? {
            if source.watching && source.path.is_dir() {
                manager
                    .inner
                    .watcher
                    .lock()
                    .watch(&source.path, RecursiveMode::Recursive)?;
            }
        }

        let event_manager = manager.clone();
        tokio::spawn(async move {
            loop {
                // Block for the first event of a burst, then drain whatever else
                // arrives during the debounce window into one batch. Without this,
                // a burst of N raw filesystem events (common during an import, or
                // when a source's own tag write-back touches a file it's watching)
                // triggered N separate full-source rescans, each one re-enqueuing
                // every not-yet-identified file all over again — the actual cause of
                // a 49-file library ballooning to a 150k+ identification queue.
                let Some(first) = receiver.recv().await else {
                    break;
                };
                let mut paths = vec![first];
                tokio::time::sleep(Duration::from_secs(2)).await;
                while let Ok(path) = receiver.try_recv() {
                    paths.push(path);
                }
                let sources = event_manager.list().unwrap_or_default();
                let mut touched = HashSet::new();
                for source in sources {
                    if source.watching
                        && paths.iter().any(|path| path.starts_with(&source.path))
                        && touched.insert(source.source_id)
                    {
                        let scanner = event_manager.clone();
                        let source_id = source.source_id;
                        match tokio::task::spawn_blocking(move || scanner.scan(source_id)).await {
                            Ok(Ok(_)) => {}
                            Ok(Err(error)) => {
                                tracing::warn!(
                                    source_id = %source_id,
                                    %error,
                                    "source reconciliation failed"
                                );
                            }
                            Err(error) => {
                                tracing::warn!(
                                    source_id = %source_id,
                                    %error,
                                    "source reconciliation task failed"
                                );
                            }
                        }
                    }
                }
            }
        });

        let periodic = manager.clone();
        tokio::spawn(async move {
            let mut timer = tokio::time::interval(Duration::from_secs(rescan_seconds));
            loop {
                timer.tick().await;
                let scanner = periodic.clone();
                match tokio::task::spawn_blocking(move || scanner.scan_all()).await {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        tracing::warn!(%error, "periodic source reconciliation failed");
                    }
                    Err(error) => {
                        tracing::warn!(%error, "periodic source reconciliation task failed");
                    }
                }
            }
        });
        Ok(manager)
    }

    #[cfg(unix)]
    pub fn mode(&self) -> StorageMode {
        self.inner.mode
    }

    pub fn identification(&self) -> IdentificationQueue {
        self.inner.identification.clone()
    }

    pub fn loudness(&self) -> LoudnessQueue {
        self.inner.loudness.clone()
    }

    pub fn list(&self) -> Result<Vec<SourceFolder>> {
        Ok(self.inner.store.source_folders()?)
    }

    pub fn add(&self, path: &Path) -> Result<SourceFolder> {
        let path = path
            .canonicalize()
            .with_context(|| format!("cannot open imported folder {}", path.display()))?;
        if !path.is_dir() {
            bail!("imported folder is not a directory: {}", path.display());
        }
        let data = self.inner.store.root().canonicalize()?;
        if path.starts_with(&data) || data.starts_with(&path) {
            bail!("imported folders and Library Data must not contain one another");
        }
        for existing in self.list()?.into_iter().filter(|source| source.watching) {
            let existing_path = existing.path.canonicalize().unwrap_or(existing.path);
            if path.starts_with(&existing_path) || existing_path.starts_with(&path) {
                bail!(
                    "imported folder overlaps existing folder {}",
                    existing_path.display()
                );
            }
        }
        let source_id = source_id(self.inner.hub_id, &path)?;
        self.inner.store.register_host_source(
            source_id,
            path.file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("Music Folder"),
            self.inner.mode.as_str(),
            &path,
        )?;
        self.inner
            .watcher
            .lock()
            .watch(&path, RecursiveMode::Recursive)?;
        self.scan(source_id)?;
        self.inner
            .store
            .source_folder(source_id)?
            .context("imported folder disappeared")
    }

    pub fn remove(&self, source_id: Uuid) -> Result<bool> {
        let Some(source) = self.inner.store.source_folder(source_id)? else {
            return Ok(false);
        };
        let _ = self.inner.watcher.lock().unwatch(&source.path);
        Ok(self.inner.store.detach_source(source_id)?)
    }

    pub fn scan_all(&self) -> Result<()> {
        for source in self.list()?.into_iter().filter(|source| source.watching) {
            if let Err(error) = self.scan(source.source_id) {
                let _ = self.inner.store.finish_source_scan(
                    source.source_id,
                    &HashSet::new(),
                    Some(&error.to_string()),
                );
            }
        }
        Ok(())
    }

    pub fn scan(&self, source_id: Uuid) -> Result<usize> {
        let _scan = self.inner.scan_lock.lock();
        let source = self
            .inner
            .store
            .source_folder(source_id)?
            .context("imported folder not found")?;
        if !source.watching {
            bail!("imported folder is detached");
        }
        if !source.path.is_dir() {
            self.inner.store.finish_source_scan(
                source_id,
                &HashSet::new(),
                Some("Imported folder is unavailable"),
            )?;
            return Ok(0);
        }
        let existing: HashMap<_, _> = self
            .inner
            .store
            .source_files(source_id)?
            .into_iter()
            .map(|file| (file.relative_path.clone(), file))
            .collect();
        let files = media_files(&source.path)?;
        let mut seen = HashSet::new();
        let mut changed = 0;
        for file in files {
            let relative = file
                .strip_prefix(&source.path)?
                .to_string_lossy()
                .replace('\\', "/");
            seen.insert(relative.clone());
            let before = file.metadata()?;
            let modified = before
                .modified()
                .ok()
                .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
                .map(|value| value.as_millis() as i64)
                .unwrap_or_default();
            let prior = existing.get(&relative);
            if let Some(prior) = prior
                && prior.size == before.len()
                && prior.modified_millis == modified
                && prior.available
            {
                if !self
                    .inner
                    .store
                    .track_metadata_has_field(prior.track_id, "sample_rate")?
                {
                    self.append_song_operation(
                        prior.track_id,
                        source_id,
                        &file,
                        &prior.content_hash,
                        prior.size,
                        changed as u32,
                    )?;
                    changed += 1;
                }
                self.maybe_enqueue_identification(&prior.content_hash, &file)?;
                self.maybe_enqueue_loudness(&prior.content_hash, &file)?;
                continue;
            }
            let imported = match self.inner.mode {
                StorageMode::Managed => self.inner.store.import_managed(&file),
                StorageMode::Referenced => self.inner.store.import_referenced(&file),
            };
            let (hash, size) = match imported {
                Ok(value) => value,
                Err(error) => {
                    // A single file's import can fail transiently — most commonly a
                    // TOCTOU size mismatch when something (Time Machine, a
                    // cloud-sync client, an in-progress copy) rewrites the file
                    // between the hash pass and the copy pass. Propagating this via
                    // `?` used to abort the *entire* scan on the first bad file —
                    // skipping every file after it in sort order, every retry — and
                    // `scan_all`'s error handler then marked the whole source
                    // unavailable on top of that. One flaky file could poison the
                    // whole library on every scan. Skipping just this file instead
                    // lets the rest of the scan proceed normally; the next scan
                    // naturally retries it.
                    tracing::warn!(
                        path = %file.display(), %error,
                        "skipping file: import failed"
                    );
                    continue;
                }
            };
            let after = file.metadata()?;
            if before.len() != after.len() || before.modified().ok() != after.modified().ok() {
                tracing::info!(path = %file.display(), "file changed while importing; retrying later");
                continue;
            }
            let track_id = prior
                .map(|value| value.track_id)
                .or(self.inner.store.track_id_for_hash(&hash)?)
                .unwrap_or_else(Uuid::new_v4);
            let needs_metadata = !self
                .inner
                .store
                .track_metadata_has_field(track_id, "sample_rate")?;
            if prior.is_none_or(|value| value.content_hash != hash || !value.available)
                || needs_metadata
            {
                self.append_song_operation(
                    track_id,
                    source_id,
                    &file,
                    &hash,
                    size,
                    changed as u32,
                )?;
                changed += 1;
            }
            self.inner
                .store
                .upsert_source_file(source_id, &relative, track_id, &hash, size, modified)?;
            self.maybe_enqueue_identification(&hash, &file)?;
            self.maybe_enqueue_loudness(&hash, &file)?;
        }
        self.inner
            .store
            .finish_source_scan(source_id, &seen, None)?;
        Ok(changed)
    }

    /// Enqueues a file for background identification if it doesn't already have a
    /// stored result. Called for every file visited during a scan — including files
    /// that are otherwise unchanged — so an existing library gets swept for
    /// identification on routine rescans, not only on first import. Keyed by content
    /// hash rather than track id: content hash is the only identifier this database
    /// shares with the macOS app's separate local library catalog, which generates
    /// its own track ids independently.
    fn maybe_enqueue_identification(&self, content_hash: &str, file: &Path) -> Result<()> {
        if !self.inner.store.has_identification_result(content_hash)? {
            self.inner
                .identification
                .enqueue(content_hash.to_string(), file.to_path_buf());
        }
        Ok(())
    }

    fn maybe_enqueue_loudness(&self, content_hash: &str, file: &Path) -> Result<()> {
        if self
            .inner
            .store
            .needs_loudness_analysis(content_hash, ALGORITHM_VERSION)?
        {
            self.inner
                .loudness
                .enqueue(content_hash.to_string(), file.to_path_buf());
        }
        Ok(())
    }

    fn append_song_operation(
        &self,
        track_id: Uuid,
        source_id: Uuid,
        file: &Path,
        hash: &str,
        size: u64,
        logical: u32,
    ) -> Result<()> {
        let timestamp = HybridTimestamp {
            physical_millis: chrono::Utc::now().timestamp_millis(),
            logical,
            device_id: self.inner.hub_id,
        };
        let payload = crate::audio_metadata::song_payload(file, hash, size, source_id);
        let field_versions = payload
            .as_object()
            .expect("song payload is an object")
            .keys()
            .map(|field| (field.clone(), timestamp.clone()))
            .collect::<BTreeMap<_, _>>();
        self.inner.store.append_operations(&[Operation {
            operation_id: Uuid::new_v4(),
            device_id: self.inner.hub_id,
            entity_type: "track".into(),
            entity_id: track_id.to_string(),
            kind: "upsert".into(),
            payload,
            field_versions,
        }])?;
        Ok(())
    }
}

fn source_id(hub_id: Uuid, path: &Path) -> Result<Uuid> {
    let mut identity = Sha256::new();
    identity.update(hub_id.as_bytes());
    identity.update(path.as_os_str().as_encoded_bytes());
    Ok(Uuid::from_slice(&identity.finalize()[..16])?)
}

fn media_files(source: &Path) -> Result<Vec<PathBuf>> {
    const EXTENSIONS: &[&str] = &[
        "aac", "aif", "aiff", "alac", "ape", "dsf", "dff", "flac", "m4a", "mp3", "ogg", "opus",
        "wav", "wv",
    ];
    let mut files = Vec::new();
    for entry in walkdir::WalkDir::new(source).follow_links(false) {
        let entry = entry?;
        if entry.file_type().is_file()
            && entry
                .path()
                .extension()
                .and_then(|value| value.to_str())
                .is_some_and(|extension| {
                    EXTENSIONS
                        .iter()
                        .any(|candidate| extension.eq_ignore_ascii_case(candidate))
                })
        {
            files.push(entry.into_path());
        }
    }
    files.sort();
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn edits_keep_song_identity_and_missing_files_are_retained() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("Music");
        let data = root.path().join("Data");
        std::fs::create_dir_all(&source).unwrap();
        let song = source.join("Song.flac");
        std::fs::write(&song, b"first version").unwrap();
        let store = HubStore::open(&data).unwrap();
        let hub_id = Uuid::new_v4();
        let identification = IdentificationQueue::start(store.clone(), hub_id, None);
        let loudness = LoudnessQueue::start(store.clone(), hub_id);
        let manager = SourceManager::start(
            store.clone(),
            hub_id,
            StorageMode::Managed,
            3_600,
            identification,
            loudness,
        )
        .unwrap();
        let folder = manager.add(&source).unwrap();
        let first = store.source_files(folder.source_id).unwrap().remove(0);

        std::fs::write(&song, b"second version").unwrap();
        manager.scan(folder.source_id).unwrap();
        let second = store.source_files(folder.source_id).unwrap().remove(0);
        assert_eq!(first.track_id, second.track_id);
        assert_ne!(first.content_hash, second.content_hash);

        std::fs::remove_file(song).unwrap();
        manager.scan(folder.source_id).unwrap();
        let missing = store.source_files(folder.source_id).unwrap().remove(0);
        assert_eq!(missing.track_id, first.track_id);
        assert!(!missing.available);
        assert!(manager.remove(folder.source_id).unwrap());
        assert!(
            !store
                .source_folder(folder.source_id)
                .unwrap()
                .unwrap()
                .watching
        );
    }
}
