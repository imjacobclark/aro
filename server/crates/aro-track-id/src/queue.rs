//! The background identification worker.
//!
//! `sources.rs` enqueues newly-scanned files here rather than identifying them
//! inline during a folder scan — AcoustID/MusicBrainz's rate limits (~3 req/s, ~1
//! req/s respectively) would make a large library scan take hours if identification
//! blocked it. A single serial worker consumes the queue in the background; the scan
//! itself always finishes immediately regardless of queue depth. Right-click "Sync
//! Track/Album Data" actions enqueue the same way.
//!
//! Jobs are keyed by **content hash and file path, not a track id**. This service's
//! only durable identifier for "the same file" that's actually shared with the macOS
//! app's separate local library catalog is the file's content hash — the two
//! databases generate their own track ids independently and they never coincide. See
//! `IdentificationResult` in `aro-sync-store` for the pull side of this.
//!
//! Results also propagate to *other* devices, but by a different path: if this file
//! has a `hub_track_id` in `hub.sqlite3` (i.e. it was imported via a watched source —
//! which is how sharing/hosting works today), the result is additionally written as a
//! normal CRDT `Operation` on that track. Remote clients already pull and merge track
//! operations via the existing `/sync/exchange` protocol (their own
//! `hub_track_mappings` table resolves `hub_track_id` to their local track id), so
//! this reuses proven machinery rather than inventing a second sync path. A file with
//! no `hub_track_id` yet (sharing never turned on for its folder) only gets the local,
//! content-hash-keyed result — there is no shared identity to route a remote copy by.
//!
//! ## Per-file vs. group identification
//!
//! A single file resolved in isolation (`identify_file`) has a real ceiling: for some
//! tracks, the recording actually linked to the album the user owns simply isn't among
//! AcoustID's candidate list for that file's fingerprint at all (observed directly on
//! real tracks), so no amount of ranking can select a candidate that was never offered.
//! `identify_group` sidesteps this by matching a whole folder's worth of files against a
//! specific MusicBrainz release's ordered tracklist at once (see the `album` module for
//! the actual matching algorithm) — position, duration, and title agreement across the
//! *group* pin down "this file is track 9 of this release" even when no single file's
//! own fingerprint match would have.
//!
//! Files offered to [`IdentificationQueue::enqueue`] are coalesced by parent directory
//! (see [`coalesce`]) before reaching the worker, so a full-folder scan becomes one
//! [`WorkItem::Group`] rather than dozens of independent per-file jobs. A folder that
//! doesn't corroborate a shared release (mixed-bag, or plain rejected by
//! `album::accept`) falls back to `identify_file` for every member — bit-identical to
//! the pre-grouping behaviour.

use crate::{acoustid, album, fingerprint, musicbrainz, tags};
use aro_sync_protocol::{HybridTimestamp, Operation};
use aro_sync_store::{HubStore, IdentificationResult};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    cmp::Reverse,
    collections::{BTreeMap, HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    sync::{Mutex, mpsc},
    time::Instant,
};
use uuid::Uuid;

/// How long a cached AcoustID/MusicBrainz response is trusted before a re-fetch is
/// attempted on next access — MusicBrainz metadata can be corrected by the community
/// after we first cache it.
const CACHE_TTL_SECS: i64 = 30 * 24 * 60 * 60;

/// A folder must stop receiving newly-staged files for at least this long before the
/// coalescer flushes it as one group — long enough that a full-folder scan (which
/// enqueues every file in a tight burst) reliably lands in a single group rather than
/// splitting across several.
const GROUP_DEBOUNCE_SECS: u64 = 5;
/// Upper bound on how long a folder can keep accepting newly-staged files before it's
/// flushed regardless of debounce — bounds a slow or unusually large scan.
const MAX_GROUP_STAGING_SECS: u64 = 60;
/// A folder with more members than this either skips group matching entirely (see
/// [`send_group`]) or, if reached mid-staging, forces an immediate flush.
const MAX_GROUP_SIZE: usize = 64;
const COALESCE_TICK: Duration = Duration::from_millis(500);
/// Below this many successfully-prepared files there's no meaningful "group" to
/// corroborate a release against — a lone file (or a folder where every other file
/// failed to prepare) just goes through the ordinary per-file path.
const MIN_GROUP_MEMBERS_FOR_MATCHING: usize = 2;
/// How many of a group's shortlisted candidate releases ever get a full tracklist
/// fetch — the cap that keeps a group pass's added request cost small and bounded
/// regardless of folder size (shortlisting itself, in `album::shortlist_candidates`,
/// costs no requests at all).
const MAX_TRACKLIST_FETCHES: usize = 3;

#[derive(Clone)]
pub struct IdentificationConfig {
    pub acoustid_api_key: String,
    pub musicbrainz_user_agent: String,
}

#[derive(Clone, Debug)]
pub struct IdentificationJob {
    pub content_hash: String,
    pub path: PathBuf,
}

#[derive(Clone, Debug, Serialize)]
pub struct GroupSummary {
    pub folder: String,
    pub member_count: usize,
    pub accepted: bool,
    pub release_title: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct QueueStatus {
    pub queued: u64,
    pub in_flight: bool,
    pub processed: u64,
    pub failed: u64,
    pub last_error: Option<String>,
    pub groups_queued: u64,
    pub last_group: Option<GroupSummary>,
}

#[derive(Clone)]
pub struct IdentificationQueue {
    inner: Arc<Inner>,
}

struct Inner {
    sender: mpsc::UnboundedSender<IdentificationJob>,
    queued: AtomicU64,
    in_flight: AtomicBool,
    processed: AtomicU64,
    failed: AtomicU64,
    last_error: Mutex<Option<String>>,
    groups_queued: AtomicU64,
    last_group: Mutex<Option<GroupSummary>>,
    /// Content hashes currently queued (staged or dequeued) or being processed.
    /// `sources.rs` calls `enqueue` for every file on every scan (by design, so an
    /// existing library gets swept on routine rescans), which means the same
    /// not-yet-identified file can be offered repeatedly before its first job
    /// finishes. Without this guard each offer added a fresh duplicate job — a
    /// handful of scan passes was enough to blow a small library's queue depth up by
    /// orders of magnitude. Membership is released by [`PendingGuard`], not by hand,
    /// so every exit path (success, error, or a panic unwinding through
    /// `identify_file`/`identify_group`) reliably clears it — with grouping, a leaked
    /// entry blocks not just one file but an entire folder from ever being
    /// re-enqueued until restart.
    pending: StdMutex<HashSet<String>>,
}

impl IdentificationQueue {
    /// Starts the background worker. `config` is `None` until a user provides an
    /// AcoustID API key in Settings; in that state `enqueue` is a documented no-op
    /// rather than an error, since queueing is a normal, expected state before setup.
    pub fn start(store: HubStore, hub_id: Uuid, config: Option<IdentificationConfig>) -> Self {
        let (staging_sender, staging_receiver) = mpsc::unbounded_channel::<IdentificationJob>();
        let inner = Arc::new(Inner {
            sender: staging_sender,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            groups_queued: AtomicU64::new(0),
            last_group: Mutex::new(None),
            pending: StdMutex::new(HashSet::new()),
        });

        if let Some(config) = config {
            let (job_sender, job_receiver) = mpsc::unbounded_channel::<WorkItem>();
            tokio::spawn(coalesce(inner.clone(), store.clone(), staging_receiver, job_sender));

            let acoustid = acoustid::AcoustIdClient::new(config.acoustid_api_key);
            let musicbrainz_user_agent = config.musicbrainz_user_agent;
            let musicbrainz = musicbrainz::MusicBrainzClient::new(musicbrainz_user_agent.clone());
            let artwork_http = reqwest::Client::new();
            tokio::spawn(run(
                inner.clone(),
                store,
                hub_id,
                acoustid,
                musicbrainz,
                artwork_http,
                musicbrainz_user_agent,
                job_receiver,
            ));
        } else {
            tracing::info!("track identification disabled: no AcoustID API key configured");
        }

        Self { inner }
    }

    /// Enqueues a file for background identification. No-op if the queue was never
    /// started (no API key configured yet), or if this content hash already has a
    /// job queued or in flight — callers offer the same not-yet-identified file on
    /// every scan pass by design, so this is the guard against that turning into
    /// unbounded duplicate work. Feeds the coalescer (see [`coalesce`]), not the
    /// worker directly — a burst of files from one folder scan is what turns into a
    /// single group.
    pub fn enqueue(&self, content_hash: String, path: PathBuf) {
        {
            let mut pending = self.inner.pending.lock().unwrap();
            if !pending.insert(content_hash.clone()) {
                return;
            }
        }
        let job = IdentificationJob {
            content_hash: content_hash.clone(),
            path,
        };
        if self.inner.sender.send(job).is_ok() {
            self.inner.queued.fetch_add(1, Ordering::Relaxed);
        } else {
            self.inner.pending.lock().unwrap().remove(&content_hash);
        }
    }

    pub async fn status(&self) -> QueueStatus {
        QueueStatus {
            queued: self.inner.queued.load(Ordering::Relaxed),
            in_flight: self.inner.in_flight.load(Ordering::Relaxed),
            processed: self.inner.processed.load(Ordering::Relaxed),
            failed: self.inner.failed.load(Ordering::Relaxed),
            last_error: self.inner.last_error.lock().await.clone(),
            groups_queued: self.inner.groups_queued.load(Ordering::Relaxed),
            last_group: self.inner.last_group.lock().await.clone(),
        }
    }
}

/// One unit of work handed from the coalescer to the serial worker: either a lone file
/// (too small a "group" to meaningfully corroborate a release, or the queue's config
/// disabled — see [`send_group`]), or a folder's worth of files to match as a group.
enum WorkItem {
    Single(IdentificationJob),
    Group(GroupJob),
}

impl WorkItem {
    fn content_hashes(&self) -> Vec<String> {
        match self {
            WorkItem::Single(job) => vec![job.content_hash.clone()],
            WorkItem::Group(group) => group.jobs.iter().map(|job| job.content_hash.clone()).collect(),
        }
    }

    fn member_count(&self) -> u64 {
        match self {
            WorkItem::Single(_) => 1,
            WorkItem::Group(group) => group.jobs.len() as u64,
        }
    }
}

struct GroupJob {
    folder: PathBuf,
    jobs: Vec<IdentificationJob>,
}

struct StagedGroup {
    jobs: Vec<IdentificationJob>,
    first_staged: Instant,
    last_staged: Instant,
}

/// Buffers files staged via [`IdentificationQueue::enqueue`] by parent directory and
/// flushes each folder as one [`WorkItem`] once it looks like a scan has finished
/// offering that folder's files — see the module doc for why grouping matters. Runs as
/// its own task so `enqueue` itself stays a cheap, synchronous, non-blocking call (it's
/// invoked from `spawn_blocking` scan code in `sources.rs`).
async fn coalesce(
    inner: Arc<Inner>,
    store: HubStore,
    mut staging_receiver: mpsc::UnboundedReceiver<IdentificationJob>,
    job_sender: mpsc::UnboundedSender<WorkItem>,
) {
    let mut staged: HashMap<PathBuf, StagedGroup> = HashMap::new();
    let mut ticker = tokio::time::interval(COALESCE_TICK);

    loop {
        tokio::select! {
            job = staging_receiver.recv() => {
                let Some(job) = job else {
                    flush_all(&inner, &store, &mut staged, &job_sender);
                    return;
                };
                let folder = job
                    .path
                    .parent()
                    .map(Path::to_path_buf)
                    .unwrap_or_else(|| job.path.clone());
                let now = Instant::now();
                let force_flush = {
                    let group = staged.entry(folder.clone()).or_insert_with(|| StagedGroup {
                        jobs: Vec::new(),
                        first_staged: now,
                        last_staged: now,
                    });
                    group.jobs.push(job);
                    group.last_staged = now;
                    group.jobs.len() >= MAX_GROUP_SIZE
                };
                if force_flush && let Some(group) = staged.remove(&folder) {
                    send_group(&inner, &store, folder, group.jobs, &job_sender);
                }
            }
            _ = ticker.tick() => {
                flush_ready(&inner, &store, &mut staged, &job_sender);
            }
        }
    }
}

fn flush_ready(
    inner: &Arc<Inner>,
    store: &HubStore,
    staged: &mut HashMap<PathBuf, StagedGroup>,
    job_sender: &mpsc::UnboundedSender<WorkItem>,
) {
    let now = Instant::now();
    let ready: Vec<PathBuf> = staged
        .iter()
        .filter(|(_, group)| {
            now.duration_since(group.last_staged) >= Duration::from_secs(GROUP_DEBOUNCE_SECS)
                || now.duration_since(group.first_staged) >= Duration::from_secs(MAX_GROUP_STAGING_SECS)
        })
        .map(|(folder, _)| folder.clone())
        .collect();

    flush_folders(inner, store, staged, ready, job_sender);
}

fn flush_all(
    inner: &Arc<Inner>,
    store: &HubStore,
    staged: &mut HashMap<PathBuf, StagedGroup>,
    job_sender: &mpsc::UnboundedSender<WorkItem>,
) {
    let all: Vec<PathBuf> = staged.keys().cloned().collect();
    flush_folders(inner, store, staged, all, job_sender);
}

/// Largest folder first — lets the biggest, most-corroborated group seed artist
/// affinity (via `record_release_group_choice`) before that artist's stray singles,
/// in a different folder, are processed.
fn flush_folders(
    inner: &Arc<Inner>,
    store: &HubStore,
    staged: &mut HashMap<PathBuf, StagedGroup>,
    folders: Vec<PathBuf>,
    job_sender: &mpsc::UnboundedSender<WorkItem>,
) {
    let mut ready_groups: Vec<(PathBuf, StagedGroup)> = folders
        .into_iter()
        .filter_map(|folder| staged.remove(&folder).map(|group| (folder, group)))
        .collect();
    ready_groups.sort_by_key(|(_, group)| Reverse(group.jobs.len()));

    for (folder, group) in ready_groups {
        send_group(inner, store, folder, group.jobs, job_sender);
    }
}

fn send_group(
    inner: &Arc<Inner>,
    store: &HubStore,
    folder: PathBuf,
    staged_jobs: Vec<IdentificationJob>,
    job_sender: &mpsc::UnboundedSender<WorkItem>,
) {
    // Union with the folder's full membership (not just the files this particular scan
    // pass happened to stage) so a single manually re-synced file still gets its whole
    // folder as group context — see `HubStore::folder_members`'s doc comment.
    let mut by_hash: HashMap<String, IdentificationJob> = staged_jobs
        .into_iter()
        .map(|job| (job.content_hash.clone(), job))
        .collect();
    if let Ok(members) = store.folder_members(&folder) {
        for member in members {
            by_hash.entry(member.content_hash.clone()).or_insert(IdentificationJob {
                content_hash: member.content_hash,
                path: member.path,
            });
        }
    }
    let jobs: Vec<IdentificationJob> = by_hash.into_values().collect();

    if jobs.len() > MAX_GROUP_SIZE {
        // A flat, dumping-ground-style folder — group matching could still only ever cost
        // a bounded `MAX_TRACKLIST_FETCHES` extra requests even here, but there's no
        // plausible single release to corroborate across this many files, so skip
        // straight to per-file rather than spending those requests on a match that will
        // always be rejected.
        tracing::info!(folder = %folder.display(), members = jobs.len(), "folder exceeds group size limit; identifying each file individually");
        for job in jobs {
            let _ = job_sender.send(WorkItem::Single(job));
        }
        return;
    }

    let item = if jobs.len() >= MIN_GROUP_MEMBERS_FOR_MATCHING {
        inner.groups_queued.fetch_add(1, Ordering::Relaxed);
        Some(WorkItem::Group(GroupJob { folder, jobs }))
    } else {
        jobs.into_iter().next().map(WorkItem::Single)
    };

    if let Some(item) = item {
        let _ = job_sender.send(item);
    }
}

/// Removes every member of one [`WorkItem`] from `Inner::pending` when dropped — on
/// every exit path, including a panic unwinding out of `identify_file`/`identify_group`.
/// See `Inner::pending`'s doc comment for why this must never be skipped.
struct PendingGuard<'a> {
    pending: &'a StdMutex<HashSet<String>>,
    content_hashes: Vec<String>,
}

impl<'a> PendingGuard<'a> {
    fn new(inner: &'a Inner, content_hashes: Vec<String>) -> Self {
        Self {
            pending: &inner.pending,
            content_hashes,
        }
    }
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        let mut pending = self.pending.lock().unwrap();
        for hash in &self.content_hashes {
            pending.remove(hash);
        }
    }
}

async fn run(
    inner: Arc<Inner>,
    store: HubStore,
    hub_id: Uuid,
    acoustid: acoustid::AcoustIdClient,
    musicbrainz: musicbrainz::MusicBrainzClient,
    artwork_http: reqwest::Client,
    musicbrainz_user_agent: String,
    mut receiver: mpsc::UnboundedReceiver<WorkItem>,
) {
    // Whether at least one group has been accepted since the last reconcile sweep (or
    // since startup) — the trigger condition for scheduling the next one. Local to this
    // loop, not shared state: only `run` ever decides to sweep.
    let mut groups_accepted_since_sweep = false;

    while let Some(item) = receiver.recv().await {
        inner.queued.fetch_sub(item.member_count(), Ordering::Relaxed);
        inner.in_flight.store(true, Ordering::Relaxed);
        let _pending_guard = PendingGuard::new(&inner, item.content_hashes());

        match item {
            WorkItem::Single(job) => {
                let content_hash = job.content_hash.clone();
                match identify_file(
                    &store,
                    hub_id,
                    &acoustid,
                    &musicbrainz,
                    &artwork_http,
                    &musicbrainz_user_agent,
                    job,
                )
                .await
                {
                    Ok(_) => {
                        inner.processed.fetch_add(1, Ordering::Relaxed);
                        *inner.last_error.lock().await = None;
                    }
                    Err(error) => {
                        tracing::warn!(%content_hash, %error, "track identification failed");
                        inner.failed.fetch_add(1, Ordering::Relaxed);
                        *inner.last_error.lock().await = Some(error.to_string());
                    }
                }
            }
            WorkItem::Group(group) => {
                let folder = group.folder.display().to_string();
                let member_count = group.jobs.len();
                let outcome = identify_group(
                    &store,
                    hub_id,
                    &acoustid,
                    &musicbrainz,
                    &artwork_http,
                    &musicbrainz_user_agent,
                    group,
                )
                .await;
                inner.processed.fetch_add(outcome.processed as u64, Ordering::Relaxed);
                inner.failed.fetch_add(outcome.failed as u64, Ordering::Relaxed);
                *inner.last_error.lock().await = if outcome.failed > 0 {
                    Some(format!("{} file(s) failed during group identification", outcome.failed))
                } else {
                    None
                };
                inner.groups_queued.fetch_sub(1, Ordering::Relaxed);
                if outcome.accepted {
                    groups_accepted_since_sweep = true;
                }
                *inner.last_group.lock().await = Some(GroupSummary {
                    folder,
                    member_count,
                    accepted: outcome.accepted,
                    release_title: outcome.release_title,
                });
            }
        }

        inner.in_flight.store(false, Ordering::Relaxed);

        // Idle-only, non-self-arming: only sweep once the coalescer/worker have nothing
        // else queued, and only schedule the *next* sweep if this one actually revised
        // something (see `reconcile_sweep`'s return value) — a sweep that revises zero
        // rows means the library has converged, and re-running it every idle tick would
        // just burn requests re-confirming the same answer forever.
        if receiver.is_empty() && groups_accepted_since_sweep {
            let revised = reconcile_sweep(
                &store,
                hub_id,
                &acoustid,
                &musicbrainz,
                &artwork_http,
                &musicbrainz_user_agent,
            )
            .await;
            groups_accepted_since_sweep = revised > 0;
        }
    }
}

const RECONCILE_BATCH: u32 = 25;

/// Revisits up to [`RECONCILE_BATCH`] folders whose files predate
/// `crate::IDENTIFICATION_GENERATION` (see `HubStore::folders_needing_reconcile`), running
/// each through the same group-matching path as an ordinary scan. This is what lets a file
/// whose per-file answer was written before its artist's affinity converged (or before a
/// sibling folder existed at all) eventually pick up the better group-quality answer,
/// without needing every file to have been processed in the "right" order to begin with —
/// see the module doc's cold-start discussion.
///
/// Returns how many files were actually revised (their answer's content changed, not just
/// their generation marker) — `run`'s trigger uses this to decide whether another sweep is
/// worth scheduling. Every visited file's `resolution_generation` is advanced to the
/// current generation regardless of whether it was revised (via
/// `HubStore::touch_identification_generation`), which is what makes each file eligible for
/// at most one reconcile attempt per generation — the sweep is therefore guaranteed to
/// terminate rather than relying on a heuristic stopping condition.
async fn reconcile_sweep(
    store: &HubStore,
    hub_id: Uuid,
    acoustid: &acoustid::AcoustIdClient,
    musicbrainz: &musicbrainz::MusicBrainzClient,
    artwork_http: &reqwest::Client,
    musicbrainz_user_agent: &str,
) -> usize {
    let folders = match store
        .folders_needing_reconcile(i64::from(crate::IDENTIFICATION_GENERATION), RECONCILE_BATCH)
    {
        Ok(folders) => folders,
        Err(error) => {
            tracing::warn!(%error, "failed to list folders needing reconcile");
            return 0;
        }
    };
    if folders.is_empty() {
        return 0;
    }
    tracing::info!(folder_count = folders.len(), "starting reconcile sweep");

    let mut revised = 0usize;
    for folder in folders {
        let jobs: Vec<IdentificationJob> = match store.folder_members(&folder) {
            Ok(members) => members
                .into_iter()
                .map(|member| IdentificationJob {
                    content_hash: member.content_hash,
                    path: member.path,
                })
                .collect(),
            Err(error) => {
                tracing::warn!(folder = %folder.display(), %error, "failed to list folder members for reconcile");
                continue;
            }
        };
        if jobs.is_empty() {
            continue;
        }

        // Snapshot the "shape" of each file's current answer, not just its timestamp —
        // `identified_at` alone could coincidentally collide at second granularity between
        // an old and a genuinely rewritten answer within the same sweep.
        let before: HashMap<String, ResultShape> = jobs
            .iter()
            .filter_map(|job| {
                store
                    .identification_result(&job.content_hash)
                    .ok()
                    .flatten()
                    .map(|result| (job.content_hash.clone(), ResultShape::from(&result)))
            })
            .collect();

        identify_group(
            store,
            hub_id,
            acoustid,
            musicbrainz,
            artwork_http,
            musicbrainz_user_agent,
            GroupJob {
                folder: folder.clone(),
                jobs: jobs.clone(),
            },
        )
        .await;

        for job in &jobs {
            if let Err(error) = store.touch_identification_generation(
                &job.content_hash,
                i64::from(crate::IDENTIFICATION_GENERATION),
            ) {
                tracing::warn!(content_hash = %job.content_hash, %error, "failed to advance reconcile generation");
            }

            let after = store
                .identification_result(&job.content_hash)
                .ok()
                .flatten()
                .map(|result| ResultShape::from(&result));
            if after != before.get(&job.content_hash).cloned() {
                revised += 1;
            }
        }
    }
    tracing::info!(revised, "reconcile sweep complete");
    revised
}

/// The parts of an [`IdentificationResult`] that constitute a materially different answer
/// — used only to detect whether a reconcile pass actually changed anything (see
/// [`reconcile_sweep`]), deliberately excluding `identified_at` (a timestamp isn't itself a
/// different answer) and `resolution_generation` (advanced unconditionally by the sweep,
/// so it can't be used to detect a real revision).
#[derive(Clone, PartialEq, Eq)]
struct ResultShape {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    release_id: Option<String>,
    resolution_source: Option<String>,
}

impl From<&IdentificationResult> for ResultShape {
    fn from(result: &IdentificationResult) -> Self {
        Self {
            title: result.title.clone(),
            artist: result.artist.clone(),
            album: result.album.clone(),
            release_id: result.release_id.clone(),
            resolution_source: result.resolution_source.clone(),
        }
    }
}

/// Returns `Ok(true)` if a result was found and stored, `Ok(false)` if nothing usable
/// was found upstream (not an error — just try again later, e.g. via a manual "Sync
/// Track Data"). Errors are reserved for genuine failures (decode error, network
/// error, etc.), not "no match."
async fn identify_file(
    store: &HubStore,
    hub_id: Uuid,
    acoustid: &acoustid::AcoustIdClient,
    musicbrainz: &musicbrainz::MusicBrainzClient,
    artwork_http: &reqwest::Client,
    musicbrainz_user_agent: &str,
    job: IdentificationJob,
) -> anyhow::Result<bool> {
    let Some(prepared) = prepare_file(store, acoustid, musicbrainz, job).await? else {
        return Ok(false);
    };
    finish_per_file(store, hub_id, artwork_http, musicbrainz_user_agent, &prepared).await
}

/// A file's fingerprint/AcoustID/MusicBrainz evidence, gathered once and reusable both
/// by the ordinary per-file path and by group matching. Deliberately holds only the
/// scalar fields actually needed, not the raw `acoustid::LookupResponse` — retaining a
/// fully parsed response per file for an entire folder's worth of files at once (as
/// group matching does) is the difference between kilobytes and megabytes on the
/// ~900MB Raspberry Pi this service targets.
struct PreparedFile {
    job: IdentificationJob,
    duration_secs: u32,
    tags: tags::ExistingTags,
    acoustid_id: String,
    /// The MusicBrainz recording MBID AcoustID's chosen candidate links to, if any —
    /// distinct from `acoustid_id` (the AcoustID *match* id). This is the id
    /// `musicbrainz.recording()` was fetched with.
    acoustid_recording_id: Option<String>,
    /// Every recording id AcoustID linked for this file's fingerprint, not just the
    /// chosen candidate — a candidate that lost the per-file ranking is still good
    /// evidence for "which release is this" in group matching (see
    /// `album::GroupFile::candidate_recording_ids`'s doc comment).
    candidate_recording_ids: Vec<String>,
    acoustid_title: Option<String>,
    acoustid_artist: Option<String>,
    acoustid_album: Option<String>,
    musicbrainz_recording: Option<musicbrainz::RecordingResponse>,
}

/// Fingerprints the file, looks it up (cache-first, per [`is_fresh`]), and resolves the
/// best AcoustID/MusicBrainz candidate — everything from `identify_file`'s original body
/// up to (not including) building the persisted `fields` map. Returns `Ok(None)` for
/// every "nothing usable, try again later" case (unsupported format, no confident
/// AcoustID match), mirroring `identify_file`'s original `Ok(false)` returns.
async fn prepare_file(
    store: &HubStore,
    acoustid: &acoustid::AcoustIdClient,
    musicbrainz: &musicbrainz::MusicBrainzClient,
    job: IdentificationJob,
) -> anyhow::Result<Option<PreparedFile>> {
    let fingerprinted = {
        let path = job.path.clone();
        tokio::task::spawn_blocking(move || fingerprint::fingerprint_file(&path)).await?
    };
    let fingerprint::FingerprintResult {
        fingerprint_base64,
        duration_secs,
    } = match fingerprinted {
        Ok(result) => result,
        Err(fingerprint::Error::UnsupportedFormat(reason)) => {
            tracing::debug!(
                content_hash = %job.content_hash, %reason,
                "skipping identification: unsupported audio format"
            );
            return Ok(None);
        }
        Err(error) => return Err(error.into()),
    };
    tracing::info!(
        content_hash = %job.content_hash,
        path = %job.path.display(),
        fingerprint_len = fingerprint_base64.len(),
        duration_secs,
        "fingerprinted; querying acoustid"
    );

    // Purely a disambiguation hint for `acoustid::best_match` (see its doc comment
    // for why): a single AcoustID fingerprint can carry several unrelated candidate
    // recordings, and the file's own existing tags — when it has them — are a
    // strong signal for which one is actually right. Never persisted or trusted on
    // its own.
    let existing_tags = {
        let path = job.path.clone();
        tokio::task::spawn_blocking(move || tags::read_existing_tags(&path)).await?
    };
    let hint = acoustid::RecordingHint {
        title: existing_tags.title.as_deref(),
        artist: existing_tags.artist.as_deref(),
    };

    let cached = store.identification_cache_get(&fingerprint_base64)?;
    let fresh = cached
        .as_ref()
        .is_some_and(|entry| is_fresh(entry, chrono::Utc::now().timestamp()));

    let (acoustid_json, musicbrainz_json) = if fresh {
        let entry = cached.expect("checked by `fresh` above");
        (entry.acoustid_response, entry.musicbrainz_response)
    } else {
        match acoustid.lookup(&fingerprint_base64, duration_secs).await {
            Ok(lookup) => {
                let acoustid_json = serde_json::to_value(&lookup).ok();
                let known_release_titles = candidate_affinity_titles(store, &lookup)?;
                let musicbrainz_json =
                    match acoustid::best_match(&lookup, hint, &known_release_titles) {
                        Some((_, Some(recording))) => {
                            match musicbrainz.recording(&recording.id).await {
                                Ok(response) => serde_json::to_value(&response).ok(),
                                Err(error) => {
                                    tracing::warn!(
                                        content_hash = %job.content_hash, %error,
                                        "musicbrainz enrichment failed; keeping AcoustID-only data"
                                    );
                                    None
                                }
                            }
                        }
                        _ => None,
                    };
                store.identification_cache_put(
                    &fingerprint_base64,
                    acoustid_json.as_ref(),
                    musicbrainz_json.as_ref(),
                    crate::CACHE_SCHEMA_VERSION,
                )?;
                (acoustid_json, musicbrainz_json)
            }
            // The live re-fetch itself failed (network down, AcoustID outage, rate-limited
            // upstream...). If a stale cached answer exists, reuse it rather than erroring
            // the whole file out — this matters most right after a `CACHE_SCHEMA_VERSION`
            // bump, which marks every existing row stale at once: without this fallback, a
            // degraded network at that exact moment would make every already-identified
            // file in the library fail instead of keeping its last known-good answer. Only
            // a genuinely uncached file (nothing to fall back to) still propagates the
            // error.
            Err(error) => match cached {
                Some(entry) => {
                    tracing::warn!(
                        content_hash = %job.content_hash, %error,
                        "re-fetch failed; reusing stale cached identification"
                    );
                    (entry.acoustid_response, entry.musicbrainz_response)
                }
                None => return Err(error.into()),
            },
        }
    };

    let Some(acoustid_json) = acoustid_json else {
        return Ok(None);
    };
    let lookup: acoustid::LookupResponse = serde_json::from_value(acoustid_json)?;
    let known_release_titles = candidate_affinity_titles(store, &lookup)?;
    let Some((result, recording)) = acoustid::best_match(&lookup, hint, &known_release_titles)
    else {
        tracing::info!(
            content_hash = %job.content_hash,
            path = %job.path.display(),
            result_count = lookup.results.len(),
            "acoustid returned no usable match"
        );
        return Ok(None);
    };

    let candidate_recording_ids = lookup
        .results
        .iter()
        .flat_map(|result| result.recordings.iter())
        .map(|recording| recording.id.clone())
        .collect();
    let acoustid_recording_id = recording.map(|recording| recording.id.clone());
    let acoustid_title = recording.and_then(|recording| recording.title.clone());
    let acoustid_artist = recording.and_then(|recording| {
        recording
            .artists
            .first()
            .and_then(|artist| artist.name.clone())
    });
    let acoustid_album = recording.and_then(|recording| {
        recording
            .releasegroups
            .first()
            .and_then(|group| group.title.clone())
    });
    let musicbrainz_recording = musicbrainz_json
        .and_then(|json| serde_json::from_value::<musicbrainz::RecordingResponse>(json).ok());

    Ok(Some(PreparedFile {
        job,
        duration_secs,
        tags: existing_tags,
        acoustid_id: result.id.clone(),
        acoustid_recording_id,
        candidate_recording_ids,
        acoustid_title,
        acoustid_artist,
        acoustid_album,
        musicbrainz_recording,
    }))
}

/// [`per_file_fields`]'s output: the `fields` map plus the release identity it settled on
/// (if any), so a caller can record accurate `resolution_source`/`release_id`/
/// `release_group_id` provenance without re-deriving it from the map's string values.
struct PerFileFields {
    fields: serde_json::Map<String, Value>,
    release_id: Option<String>,
    release_group_id: Option<String>,
}

/// Builds the `fields` map for one already-prepared file — the AcoustID baseline
/// title/artist/album, overridden by MusicBrainz's if enrichment succeeded, plus
/// `select_release`'s album/artwork choice and the affinity write-back. `hint_album` is
/// passed separately (rather than always using `prepared.tags.album`) so a group match's
/// leftover files can be given the winning release's title as a much stronger hint than
/// their own (possibly wrong or absent) album tag — see `identify_group`.
async fn per_file_fields(
    prepared: &PreparedFile,
    store: &HubStore,
    artwork_http: &reqwest::Client,
    musicbrainz_user_agent: &str,
    hint_album: Option<&str>,
) -> anyhow::Result<PerFileFields> {
    let mut release_id = None;
    let mut release_group_id = None;
    let mut fields = serde_json::Map::new();
    fields.insert("acoustid_id".into(), json!(prepared.acoustid_id));
    if let Some(recording_id) = &prepared.acoustid_recording_id {
        fields.insert("musicbrainz_recording_id".into(), json!(recording_id));
    }
    if let Some(title) = &prepared.acoustid_title {
        fields.insert("title".into(), json!(title));
    }
    if let Some(artist) = &prepared.acoustid_artist {
        fields.insert("artist".into(), json!(artist));
    }
    if let Some(album) = &prepared.acoustid_album {
        fields.insert("album".into(), json!(album));
    }

    if let Some(recording) = &prepared.musicbrainz_recording {
        if let Some(title) = &recording.title {
            fields.insert("title".into(), json!(title));
        }
        if let Some(artist) = recording
            .artist_credit
            .first()
            .and_then(|credit| credit.name.clone())
        {
            fields.insert("artist".into(), json!(artist));
        }
        // Keyed by the best artist name resolved so far (MusicBrainz's, or
        // AcoustID's if MusicBrainz didn't have one) — this is what
        // `record_release_group_choice`/`release_group_affinity_rows` use to let a
        // release-group snowball across an artist's tracks.
        // A track with no resolved artist at all (rare — AcoustID/MusicBrainz both
        // came back artist-less) just gets no affinity signal either way.
        let artist_normalized = fields
            .get("artist")
            .and_then(Value::as_str)
            .map(crate::matching::normalize_matching_key);
        let affinity = match artist_normalized.as_deref() {
            Some(artist) => {
                musicbrainz::AffinityIndex::from_rows(&store.release_group_affinity_rows(artist)?)
            }
            None => Default::default(),
        };

        if let Some(release) =
            musicbrainz::select_release(&recording.releases, hint_album, &affinity)
        {
            release_id = Some(release.id.clone());
            release_group_id = release
                .release_group
                .as_ref()
                .and_then(|group| group.id.clone());
            if let Some(album) = &release.title {
                fields.insert("album".into(), json!(album));
            }
            if let Some(artwork_url) =
                cache_artwork(artwork_http, musicbrainz_user_agent, store, &release.id).await
            {
                fields.insert("artwork_url".into(), json!(artwork_url));
            }
            if let Some(artist) = artist_normalized.as_deref()
                && let Some(release_group_id) = release_group_id.as_deref()
            {
                store.record_release_group_choice(
                    artist,
                    release_group_id,
                    release.title.as_deref(),
                )?;
            }
        }
    }

    Ok(PerFileFields {
        fields,
        release_id,
        release_group_id,
    })
}

/// How an identification result was produced, so [`should_revise`] can decide whether a new
/// write is allowed to overwrite an existing one — see its doc comment for the rule.
struct ResolutionMeta {
    source: &'static str,
    score: Option<f64>,
    release_id: Option<String>,
    release_group_id: Option<String>,
}

impl ResolutionMeta {
    fn per_file(release_id: Option<String>, release_group_id: Option<String>) -> Self {
        Self {
            source: "per_file",
            score: None,
            release_id,
            release_group_id,
        }
    }

    fn group(score: f64, release_id: String, release_group_id: Option<String>) -> Self {
        Self {
            source: "group",
            score: Some(score),
            release_id: Some(release_id),
            release_group_id,
        }
    }
}

/// The minimum score improvement a new scored (`group`/`reconcile`) result must show over
/// an existing scored result before it's allowed to replace it.
const MIN_REVISION_MARGIN: f64 = 0.05;
/// Floating-point slack on the margin check — scores are weighted sums of several terms
/// (see `album::pair_score`), so two scores a "clean" 0.05 apart can differ from that by a
/// binary-floating-point rounding hair (e.g. `0.85 - 0.80` is `0.049999...`, not exactly
/// `0.05`) without being meaningfully different evidence.
const REVISION_MARGIN_EPSILON: f64 = 1e-9;

/// Whether a new write is allowed to overwrite `existing` in `identification_results`.
/// Implements two of the three revision cases from this session's design (the third —
/// "more sibling corroboration" — needs contextual sibling-agreement counts this function
/// doesn't have, and was intentionally left out; these two already cover the structurally
/// important case):
///
/// 1. No existing row, or the existing row is unscored (`per_file`, or predates this
///    column entirely) — always allow. This is the common upgrade path, and preserves every
///    prior write's unconditional-overwrite behaviour for files that never involved
///    grouping at all.
/// 2. The existing row *is* scored (`group`/`reconcile`) — only allow if the new write is
///    also scored and beats it by at least [`MIN_REVISION_MARGIN`]. This is what stops an
///    unrelated re-scan (e.g. a new sibling file joining an already-identified folder, which
///    re-runs `identify_group` for the whole folder and can therefore reprocess
///    already-well-identified files too) from silently downgrading a confident group match
///    back to a worse per-file guess — monotonic, so a scored answer, once set, is never
///    replaced by an unscored or lower-scoring one.
fn should_revise(existing: Option<&IdentificationResult>, new_score: Option<f64>) -> bool {
    let Some(existing) = existing else {
        return true;
    };
    let existing_is_scored = matches!(
        existing.resolution_source.as_deref(),
        Some("group") | Some("reconcile")
    );
    if !existing_is_scored {
        return true;
    }
    match new_score {
        Some(new_score) => {
            new_score - existing.resolution_score.unwrap_or(f64::MIN)
                >= MIN_REVISION_MARGIN - REVISION_MARGIN_EPSILON
        }
        None => false,
    }
}

/// Persists an identified file's `fields`: the revision-rule gate (see [`should_revise`]),
/// the title-presence gate, the `identification_results` row, the CRDT propagation to other
/// paired devices, and the optional tag write-back. Returns `Ok(false)` if `fields` carries
/// no title (see the inline comment for why that's deliberate); returns `Ok(true)` without
/// writing if an existing, better-sourced result is kept in place — from the caller's
/// perspective this file is still successfully resolved, just not by this write.
async fn persist_result(
    store: &HubStore,
    hub_id: Uuid,
    path: &Path,
    content_hash: &str,
    fields: serde_json::Map<String, Value>,
    meta: &ResolutionMeta,
) -> anyhow::Result<bool> {
    let text_field = |fields: &serde_json::Map<String, Value>, key: &str| {
        fields.get(key).and_then(Value::as_str).map(str::to_owned)
    };

    // A match with no title (AcoustID matched a fingerprint but the match has no
    // MusicBrainz recording link, or the link carried no title) isn't useful data —
    // it's just noise the user asked to see resolved. Deliberately NOT persisted:
    // `identification_results` presence is what gates the automatic scan sweep from
    // re-enqueuing a file (see `sources.rs::maybe_enqueue_identification`), so
    // writing an empty row here would permanently mark this file "done" with
    // nothing to show for it. Leaving it unwritten means it's retried on the next
    // sweep instead, in case AcoustID/MusicBrainz gain a link later.
    let Some(title) = text_field(&fields, "title") else {
        tracing::info!(
            content_hash = %content_hash,
            path = %path.display(),
            "identification matched but no titled recording; not marking as identified"
        );
        return Ok(false);
    };

    let existing = store.identification_result(content_hash)?;
    if !should_revise(existing.as_ref(), meta.score) {
        tracing::debug!(
            content_hash = %content_hash,
            path = %path.display(),
            existing_source = existing.as_ref().and_then(|result| result.resolution_source.clone()),
            "keeping existing higher-confidence identification result"
        );
        return Ok(true);
    }

    let identification_result = IdentificationResult {
        content_hash: content_hash.to_string(),
        title: Some(title),
        artist: text_field(&fields, "artist"),
        album: text_field(&fields, "album"),
        artwork_url: text_field(&fields, "artwork_url"),
        musicbrainz_recording_id: text_field(&fields, "musicbrainz_recording_id"),
        acoustid_id: text_field(&fields, "acoustid_id"),
        identified_at: chrono::Utc::now().timestamp(),
        resolution_source: Some(meta.source.to_string()),
        resolution_score: meta.score,
        resolution_generation: i64::from(crate::IDENTIFICATION_GENERATION),
        release_id: meta.release_id.clone(),
        release_group_id: meta.release_group_id.clone(),
    };
    tracing::info!(
        content_hash = %content_hash,
        path = %path.display(),
        title = %identification_result.title.as_deref().unwrap_or_default(),
        artist = identification_result.artist.as_deref(),
        "track identified"
    );
    store.put_identification_result(&identification_result)?;

    // Best-effort propagation to other paired devices: only possible if this file
    // already has a hub_track_id (i.e. its folder has been shared at some point).
    // Files that were only ever scanned locally by the macOS app, with sharing never
    // turned on, have no shared identity to route a remote copy by — this is not an
    // error, just the boundary of what "sharing" means.
    if let Some(track_id) = store.track_id_for_hash(content_hash)? {
        let timestamp = HybridTimestamp {
            physical_millis: chrono::Utc::now().timestamp_millis(),
            logical: 0,
            device_id: hub_id,
        };
        let field_versions = fields
            .keys()
            .map(|field| (field.clone(), timestamp.clone()))
            .collect::<BTreeMap<_, _>>();
        store.append_operations(&[Operation {
            operation_id: Uuid::new_v4(),
            device_id: hub_id,
            entity_type: "track".into(),
            entity_id: track_id.to_string(),
            kind: "upsert".into(),
            payload: Value::Object(fields.clone()),
            field_versions,
        }])?;
    }

    if tags::should_persist_to_files(store)?
        && let Err(error) = tags::write_back(path, &fields)
    {
        tracing::warn!(
            content_hash = %content_hash, %error,
            "tag write-back failed; database metadata is unaffected"
        );
    }

    Ok(true)
}

async fn finish_per_file(
    store: &HubStore,
    hub_id: Uuid,
    artwork_http: &reqwest::Client,
    musicbrainz_user_agent: &str,
    prepared: &PreparedFile,
) -> anyhow::Result<bool> {
    finish_per_file_with_hint(
        store,
        hub_id,
        artwork_http,
        musicbrainz_user_agent,
        prepared,
        prepared.tags.album.as_deref(),
    )
    .await
}

async fn finish_per_file_with_hint(
    store: &HubStore,
    hub_id: Uuid,
    artwork_http: &reqwest::Client,
    musicbrainz_user_agent: &str,
    prepared: &PreparedFile,
    hint_album: Option<&str>,
) -> anyhow::Result<bool> {
    let result = per_file_fields(prepared, store, artwork_http, musicbrainz_user_agent, hint_album).await?;
    let meta = ResolutionMeta::per_file(result.release_id, result.release_group_id);
    persist_result(
        store,
        hub_id,
        &prepared.job.path,
        &prepared.job.content_hash,
        result.fields,
        &meta,
    )
    .await
}

struct GroupOutcome {
    processed: usize,
    failed: usize,
    accepted: bool,
    release_title: Option<String>,
}

/// Fetches a release's full tracklist, checking the local cache first (see
/// `HubStore::release_cache_get`/`release_cache_put`) — this is what makes repeated
/// group passes over an already-processed library cost no network requests at all.
async fn fetch_release_cached(
    store: &HubStore,
    musicbrainz: &musicbrainz::MusicBrainzClient,
    release_id: &str,
) -> Option<musicbrainz::ReleaseResponse> {
    if let Ok(Some(entry)) = store.release_cache_get(release_id)
        && entry.schema_version >= crate::CACHE_SCHEMA_VERSION
        && let Ok(response) = serde_json::from_value(entry.response)
    {
        return Some(response);
    }
    match musicbrainz.release(release_id).await {
        Ok(response) => {
            if let Ok(json) = serde_json::to_value(&response)
                && let Err(error) =
                    store.release_cache_put(release_id, &json, crate::CACHE_SCHEMA_VERSION)
            {
                tracing::warn!(release_id, %error, "failed to cache release response");
            }
            Some(response)
        }
        Err(error) => {
            tracing::warn!(release_id, %error, "release fetch failed during group matching");
            None
        }
    }
}

/// The dominant artist's consolidated affinity across a group's successfully-prepared
/// files — used only as a shortlisting/ranking tie-break signal (see
/// `album::shortlist_candidates`), never a hard requirement, so `None` (no resolvable
/// artist at all) is a safe, conservative fallback to an empty index.
fn dominant_artist_affinity(
    store: &HubStore,
    group_files: &[&PreparedFile],
) -> Option<musicbrainz::AffinityIndex> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for file in group_files {
        let artist = file
            .musicbrainz_recording
            .as_ref()
            .and_then(|recording| recording.artist_credit.first())
            .and_then(|credit| credit.name.clone())
            .or_else(|| file.acoustid_artist.clone());
        if let Some(artist) = artist {
            *counts.entry(crate::matching::normalize_matching_key(artist)).or_insert(0) += 1;
        }
    }
    let (dominant, _) = counts.into_iter().max_by_key(|(_, count)| *count)?;
    let rows = store.release_group_affinity_rows(&dominant).ok()?;
    Some(musicbrainz::AffinityIndex::from_rows(&rows))
}

/// Matches a folder's worth of files against a shortlist of candidate MusicBrainz
/// releases as a batch (see the `album` module for the algorithm) and falls back to the
/// ordinary per-file path for every member of a rejected or under-sized group. Never
/// returns an error itself — a per-file failure within the group is logged and counted,
/// not allowed to abort the rest of the folder.
async fn identify_group(
    store: &HubStore,
    hub_id: Uuid,
    acoustid: &acoustid::AcoustIdClient,
    musicbrainz: &musicbrainz::MusicBrainzClient,
    artwork_http: &reqwest::Client,
    musicbrainz_user_agent: &str,
    job: GroupJob,
) -> GroupOutcome {
    let mut processed = 0usize;
    let mut failed = 0usize;

    let mut prepared: Vec<Option<PreparedFile>> = Vec::with_capacity(job.jobs.len());
    for file_job in job.jobs {
        let content_hash = file_job.content_hash.clone();
        match prepare_file(store, acoustid, musicbrainz, file_job).await {
            Ok(result) => prepared.push(result),
            Err(error) => {
                tracing::warn!(
                    content_hash = %content_hash, %error,
                    "track identification failed during group preparation"
                );
                failed += 1;
                prepared.push(None);
            }
        }
    }

    let group_files: Vec<&PreparedFile> = prepared.iter().flatten().collect();

    /// Runs the per-file path for one already-prepared file and reports `(processed_delta,
    /// failed_delta)` rather than taking `&mut` accumulators, so callers stay simple
    /// `+=` one-liners regardless of how many call sites there are.
    async fn run_per_file(
        store: &HubStore,
        hub_id: Uuid,
        artwork_http: &reqwest::Client,
        musicbrainz_user_agent: &str,
        file: &PreparedFile,
        hint_album: Option<&str>,
    ) -> (usize, usize) {
        match finish_per_file_with_hint(store, hub_id, artwork_http, musicbrainz_user_agent, file, hint_album).await
        {
            Ok(_) => (1, 0),
            Err(error) => {
                tracing::warn!(content_hash = %file.job.content_hash, %error, "track identification failed");
                (0, 1)
            }
        }
    }

    if group_files.len() < MIN_GROUP_MEMBERS_FOR_MATCHING {
        for file in &group_files {
            let (file_processed, file_failed) = run_per_file(
                store,
                hub_id,
                artwork_http,
                musicbrainz_user_agent,
                file,
                file.tags.album.as_deref(),
            )
            .await;
            processed += file_processed;
            failed += file_failed;
        }
        return GroupOutcome {
            processed,
            failed,
            accepted: false,
            release_title: None,
        };
    }

    let files: Vec<album::GroupFile<'_>> = group_files
        .iter()
        .map(|file| album::GroupFile {
            content_hash: &file.job.content_hash,
            path: &file.job.path,
            duration_secs: file.duration_secs,
            tags: &file.tags,
            candidate_recording_ids: &file.candidate_recording_ids,
        })
        .collect();
    let releases_per_file: Vec<Vec<musicbrainz::Release>> = group_files
        .iter()
        .map(|file| {
            file.musicbrainz_recording
                .as_ref()
                .map(|recording| recording.releases.clone())
                .unwrap_or_default()
        })
        .collect();

    let affinity = dominant_artist_affinity(store, &group_files).unwrap_or_default();
    let shortlisted =
        album::shortlist_candidates(&files, &releases_per_file, &affinity, MAX_TRACKLIST_FETCHES);

    let mut matches = Vec::new();
    for release_id in &shortlisted {
        if let Some(release) = fetch_release_cached(store, musicbrainz, release_id).await {
            matches.push(album::match_group_against_release(&files, &release));
        }
    }
    matches.sort_by(|a, b| b.score.total_cmp(&a.score));

    let best = matches.first();
    let runner_up = matches.get(1);
    let accepted = best.is_some_and(|best| album::accept(best, runner_up, files.len()));

    tracing::info!(
        folder = %job.folder.display(),
        members = files.len(),
        candidates = shortlisted.len(),
        winner = best.map(|best| best.release_id.as_str()),
        winner_title = best.and_then(|best| best.release_title.as_deref()),
        score = best.map(|best| best.score),
        assigned = best.map(|best| best.assignments.len()),
        accepted,
        "group identification decision"
    );

    let release_title = best.and_then(|best| best.release_title.clone());

    if accepted {
        let best = best.expect("accepted implies a best match exists");
        let mut artwork_url: Option<String> = None;

        for assignment in &best.assignments {
            let file = group_files[assignment.file_index];
            let mut fields = serde_json::Map::new();
            fields.insert("acoustid_id".into(), json!(file.acoustid_id));
            fields.insert("musicbrainz_recording_id".into(), json!(assignment.recording_id));
            fields.insert("title".into(), json!(assignment.title));
            if let Some(artist) = assignment
                .track_artist
                .clone()
                .or_else(|| best.release_artist.clone())
            {
                fields.insert("artist".into(), json!(artist));
            }
            if let Some(album_title) = &best.release_title {
                fields.insert("album".into(), json!(album_title));
            }
            if artwork_url.is_none() {
                artwork_url =
                    cache_artwork(artwork_http, musicbrainz_user_agent, store, &best.release_id).await;
            }
            if let Some(artwork_url) = &artwork_url {
                fields.insert("artwork_url".into(), json!(artwork_url));
            }

            if let Some(artist_normalized) = fields
                .get("artist")
                .and_then(Value::as_str)
                .map(crate::matching::normalize_matching_key)
                && let Some(release_group_id) = &best.release_group_id
                && let Err(error) = store.record_release_group_choice(
                    &artist_normalized,
                    release_group_id,
                    best.release_title.as_deref(),
                )
            {
                tracing::warn!(%error, "failed to record release-group affinity");
            }

            let meta = ResolutionMeta::group(
                best.score,
                best.release_id.clone(),
                best.release_group_id.clone(),
            );
            match persist_result(store, hub_id, &file.job.path, &file.job.content_hash, fields, &meta).await {
                Ok(_) => processed += 1,
                Err(error) => {
                    tracing::warn!(
                        content_hash = %file.job.content_hash, %error,
                        "track identification failed while persisting group result"
                    );
                    failed += 1;
                }
            }
        }

        // Leftovers weren't force-assigned (see `album::assign`'s doc comment for why),
        // but they still benefit from the winning release's title as a hint far stronger
        // than whatever their own tags carry.
        for &file_index in &best.unmatched_files {
            let (file_processed, file_failed) = run_per_file(
                store,
                hub_id,
                artwork_http,
                musicbrainz_user_agent,
                group_files[file_index],
                best.release_title.as_deref(),
            )
            .await;
            processed += file_processed;
            failed += file_failed;
        }
    } else {
        for file in &group_files {
            let (file_processed, file_failed) = run_per_file(
                store,
                hub_id,
                artwork_http,
                musicbrainz_user_agent,
                file,
                file.tags.album.as_deref(),
            )
            .await;
            processed += file_processed;
            failed += file_failed;
        }
    }

    GroupOutcome {
        processed,
        failed,
        accepted,
        release_title,
    }
}

/// Whether a cached identification response is trusted as-is, with no live re-fetch. Pure
/// and independent of the store/network so it's directly unit-testable. Three independent
/// conditions, all required:
///
/// - **within TTL** — MusicBrainz metadata can be corrected by the community after we first
///   cache it, so even a perfectly shaped response is only trusted for `CACHE_TTL_SECS`.
/// - **at or above `CACHE_SCHEMA_VERSION`** — replaces an earlier one-off check for a single
///   specific missing field (`ReleaseGroup::id`, once silently absent from every entry
///   cached before this crate started capturing it) with a general mechanism: any future
///   field added to a cached response type now invalidates old entries automatically,
///   without needing another ad-hoc check like that one.
/// - **has a title** (`cached_response_has_title`) — a separate, orthogonal concern.
///   Deliberately *not* folded into the schema version: an untitled/no-match response is
///   negative-result caching ("AcoustID/MusicBrainz had nothing usable for us"), which must
///   always be retried so a track can recover once the upstream data improves — no version
///   bump ever fixes that, since the row's *shape* was never the problem.
fn is_fresh(entry: &aro_sync_store::IdentificationCacheEntry, now: i64) -> bool {
    let within_ttl = now - entry.refreshed_at < CACHE_TTL_SECS;
    within_ttl && entry.schema_version >= crate::CACHE_SCHEMA_VERSION && cached_response_has_title(entry)
}

/// Whether a cached AcoustID/MusicBrainz response pair actually resolved to a titled
/// match — see [`is_fresh`] for why an untitled response is never treated as cacheable.
fn cached_response_has_title(entry: &aro_sync_store::IdentificationCacheEntry) -> bool {
    if let Some(musicbrainz_json) = &entry.musicbrainz_response
        && let Ok(recording) =
            serde_json::from_value::<musicbrainz::RecordingResponse>(musicbrainz_json.clone())
        && recording.title.is_some()
    {
        return true;
    }
    let Some(acoustid_json) = &entry.acoustid_response else {
        return false;
    };
    let Ok(lookup) = serde_json::from_value::<acoustid::LookupResponse>(acoustid_json.clone())
    else {
        return false;
    };
    acoustid::best_match(&lookup, acoustid::RecordingHint::default(), &HashMap::new())
        .and_then(|(_, recording)| recording)
        .is_some_and(|recording| recording.title.is_some())
}

/// Fetches a release's cover art and caches it into the hub's own
/// content-addressed blob store, so it's served from this server's
/// `/v1/blobs/{hash}` (already the audio-file download endpoint, reused as-is)
/// from then on instead of every client independently hitting the Cover Art
/// Archive — including on *this* server's own next lookup of the same image,
/// since `HubStore::import_managed` is hash-deduplicated (a shared album
/// cover across many tracks is only ever fetched and stored once). Returns
/// `None` on any failure (no art available, network error, disk error) —
/// artwork is decorative, never worth failing identification over.
async fn cache_artwork(
    http: &reqwest::Client,
    user_agent: &str,
    store: &HubStore,
    release_mbid: &str,
) -> Option<String> {
    let bytes = musicbrainz::fetch_cover_art(http, user_agent, release_mbid).await?;
    let temp = tempfile::NamedTempFile::new().ok()?;
    std::fs::write(temp.path(), &bytes).ok()?;
    let (hash, _size) = store.import_managed(temp.path()).ok()?;
    Some(format!("/v1/blobs/{hash}"))
}

/// Builds the `known_release_titles` map `acoustid::best_match` uses to
/// disambiguate same-titled recordings (see its doc comment): every artist
/// name appearing anywhere among `lookup`'s candidate recordings, mapped to
/// the release titles that artist's *other* tracks have already converged on.
/// Candidates are usually all the same one or two artists, so this is a
/// handful of cheap, already-indexed lookups — not a full-library scan.
fn candidate_affinity_titles(
    store: &HubStore,
    lookup: &acoustid::LookupResponse,
) -> anyhow::Result<HashMap<String, HashSet<String>>> {
    let mut artists = HashSet::new();
    for result in &lookup.results {
        for recording in &result.recordings {
            for artist in &recording.artists {
                if let Some(name) = &artist.name {
                    artists.insert(crate::matching::normalize_matching_key(name));
                }
            }
        }
    }
    let mut known_release_titles = HashMap::new();
    for artist in artists {
        let titles = store.release_title_affinity(&artist)?;
        if !titles.is_empty() {
            known_release_titles.insert(artist, titles);
        }
    }
    Ok(known_release_titles)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aro_sync_store::IdentificationCacheEntry;

    fn entry(schema_version: u32, refreshed_at: i64, titled: bool) -> IdentificationCacheEntry {
        IdentificationCacheEntry {
            acoustid_response: None,
            musicbrainz_response: titled.then(|| {
                serde_json::json!({"id": "rec-1", "title": "Some Song", "releases": []})
            }),
            schema_version,
            refreshed_at,
        }
    }

    #[test]
    fn entry_below_current_schema_version_is_not_fresh() {
        let stale = entry(crate::CACHE_SCHEMA_VERSION - 1, 1_000, true);
        assert!(!is_fresh(&stale, 1_000));
    }

    #[test]
    fn entry_at_current_schema_version_within_ttl_is_fresh() {
        let current = entry(crate::CACHE_SCHEMA_VERSION, 1_000, true);
        assert!(is_fresh(&current, 1_000));
    }

    #[test]
    fn untitled_entry_is_never_fresh_regardless_of_schema_version() {
        let untitled = entry(crate::CACHE_SCHEMA_VERSION, 1_000, false);
        assert!(!is_fresh(&untitled, 1_000));
    }

    #[test]
    fn entry_past_ttl_is_not_fresh_even_at_current_schema_version() {
        let expired = entry(crate::CACHE_SCHEMA_VERSION, 0, true);
        assert!(!is_fresh(&expired, CACHE_TTL_SECS + 1));
    }

    fn identification_result(source: Option<&str>, score: Option<f64>) -> IdentificationResult {
        IdentificationResult {
            content_hash: "hash-1".into(),
            title: Some("Title".into()),
            artist: None,
            album: None,
            artwork_url: None,
            musicbrainz_recording_id: None,
            acoustid_id: None,
            identified_at: 1,
            resolution_source: source.map(str::to_string),
            resolution_score: score,
            resolution_generation: 0,
            release_id: None,
            release_group_id: None,
        }
    }

    #[test]
    fn no_existing_result_always_allows_revision() {
        assert!(should_revise(None, None));
        assert!(should_revise(None, Some(0.9)));
    }

    #[test]
    fn unscored_existing_result_always_allows_revision() {
        let existing = identification_result(Some("per_file"), None);
        assert!(should_revise(Some(&existing), None));
        assert!(should_revise(Some(&existing), Some(0.5)));

        let legacy = identification_result(None, None);
        assert!(should_revise(Some(&legacy), None));
    }

    #[test]
    fn scored_existing_result_rejects_an_unscored_new_write() {
        let existing = identification_result(Some("group"), Some(0.85));
        assert!(!should_revise(Some(&existing), None));
    }

    #[test]
    fn scored_existing_result_requires_the_revision_margin() {
        let existing = identification_result(Some("group"), Some(0.80));
        assert!(!should_revise(Some(&existing), Some(0.80)));
        assert!(!should_revise(Some(&existing), Some(0.84)));
        assert!(should_revise(Some(&existing), Some(0.85)));
    }

    #[test]
    fn reconcile_sourced_existing_result_is_also_protected() {
        let existing = identification_result(Some("reconcile"), Some(0.90));
        assert!(!should_revise(Some(&existing), Some(0.90)));
        assert!(should_revise(Some(&existing), Some(0.96)));
    }

    fn job(content_hash: &str, folder: &str, file_name: &str) -> IdentificationJob {
        IdentificationJob {
            content_hash: content_hash.to_string(),
            path: PathBuf::from(folder).join(file_name),
        }
    }

    fn open_store() -> (tempfile::TempDir, HubStore) {
        let directory = tempfile::tempdir().unwrap();
        let store = HubStore::open(directory.path()).unwrap();
        (directory, store)
    }

    #[tokio::test(start_paused = true)]
    async fn files_in_one_folder_coalesce_into_one_group() {
        let (_directory, store) = open_store();
        let inner = Arc::new(Inner {
            sender: mpsc::unbounded_channel().0,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            groups_queued: AtomicU64::new(0),
            last_group: Mutex::new(None),
            pending: StdMutex::new(HashSet::new()),
        });
        let (staging_tx, staging_rx) = mpsc::unbounded_channel::<IdentificationJob>();
        let (job_tx, mut job_rx) = mpsc::unbounded_channel::<WorkItem>();
        tokio::spawn(coalesce(inner, store, staging_rx, job_tx));

        staging_tx.send(job("hash-1", "Beatles/1", "01.m4a")).unwrap();
        staging_tx.send(job("hash-2", "Beatles/1", "02.m4a")).unwrap();
        staging_tx.send(job("hash-3", "Beatles/1", "03.m4a")).unwrap();

        tokio::time::advance(Duration::from_secs(GROUP_DEBOUNCE_SECS + 1)).await;

        let item = job_rx.recv().await.expect("expected one coalesced work item");
        match item {
            WorkItem::Group(group) => assert_eq!(group.jobs.len(), 3),
            WorkItem::Single(_) => panic!("expected a group, got a single-file work item"),
        }
        assert!(
            job_rx.try_recv().is_err(),
            "expected exactly one work item, not several"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_lone_file_becomes_a_single_work_item() {
        let (_directory, store) = open_store();
        let inner = Arc::new(Inner {
            sender: mpsc::unbounded_channel().0,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            groups_queued: AtomicU64::new(0),
            last_group: Mutex::new(None),
            pending: StdMutex::new(HashSet::new()),
        });
        let (staging_tx, staging_rx) = mpsc::unbounded_channel::<IdentificationJob>();
        let (job_tx, mut job_rx) = mpsc::unbounded_channel::<WorkItem>();
        tokio::spawn(coalesce(inner, store, staging_rx, job_tx));

        staging_tx.send(job("hash-1", "Loose Tracks", "track.m4a")).unwrap();
        tokio::time::advance(Duration::from_secs(GROUP_DEBOUNCE_SECS + 1)).await;

        match job_rx.recv().await.expect("expected one work item") {
            WorkItem::Single(single) => assert_eq!(single.content_hash, "hash-1"),
            WorkItem::Group(_) => panic!("expected a single-file work item for a lone file"),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn groups_flush_largest_folder_first() {
        let (_directory, store) = open_store();
        let inner = Arc::new(Inner {
            sender: mpsc::unbounded_channel().0,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            groups_queued: AtomicU64::new(0),
            last_group: Mutex::new(None),
            pending: StdMutex::new(HashSet::new()),
        });
        let (staging_tx, staging_rx) = mpsc::unbounded_channel::<IdentificationJob>();
        let (job_tx, mut job_rx) = mpsc::unbounded_channel::<WorkItem>();
        tokio::spawn(coalesce(inner, store, staging_rx, job_tx));

        // Small folder (2 files) staged first, large folder (4 files) staged second --
        // the large folder must still come out of the channel first.
        staging_tx.send(job("s1", "Small", "a.m4a")).unwrap();
        staging_tx.send(job("s2", "Small", "b.m4a")).unwrap();
        staging_tx.send(job("b1", "Big", "a.m4a")).unwrap();
        staging_tx.send(job("b2", "Big", "b.m4a")).unwrap();
        staging_tx.send(job("b3", "Big", "c.m4a")).unwrap();
        staging_tx.send(job("b4", "Big", "d.m4a")).unwrap();

        tokio::time::advance(Duration::from_secs(GROUP_DEBOUNCE_SECS + 1)).await;

        let first = job_rx.recv().await.expect("expected a work item");
        let WorkItem::Group(first_group) = first else {
            panic!("expected a group");
        };
        assert_eq!(first_group.jobs.len(), 4, "largest folder should flush first");

        let second = job_rx.recv().await.expect("expected a second work item");
        let WorkItem::Group(second_group) = second else {
            panic!("expected a group");
        };
        assert_eq!(second_group.jobs.len(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_scan_still_flushes_within_the_max_staging_window() {
        let (_directory, store) = open_store();
        let inner = Arc::new(Inner {
            sender: mpsc::unbounded_channel().0,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            groups_queued: AtomicU64::new(0),
            last_group: Mutex::new(None),
            pending: StdMutex::new(HashSet::new()),
        });
        let (staging_tx, staging_rx) = mpsc::unbounded_channel::<IdentificationJob>();
        let (job_tx, mut job_rx) = mpsc::unbounded_channel::<WorkItem>();
        tokio::spawn(coalesce(inner, store, staging_rx, job_tx));

        staging_tx.send(job("hash-1", "Slow", "a.m4a")).unwrap();
        // Keep staging just under the debounce window each time, so debounce alone would
        // never fire -- only MAX_GROUP_STAGING_SECS should force the flush.
        for _ in 0..20 {
            tokio::time::advance(Duration::from_secs(GROUP_DEBOUNCE_SECS - 1)).await;
            staging_tx.send(job("hash-2", "Slow", "b.m4a")).unwrap();
        }

        tokio::time::advance(Duration::from_secs(MAX_GROUP_STAGING_SECS)).await;

        let item = job_rx.recv().await.expect("expected the slow folder to eventually flush");
        assert!(matches!(item, WorkItem::Group(_) | WorkItem::Single(_)));
    }

    #[test]
    fn pending_guard_releases_every_member_on_drop() {
        let inner = Inner {
            sender: mpsc::unbounded_channel().0,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            groups_queued: AtomicU64::new(0),
            last_group: Mutex::new(None),
            pending: StdMutex::new(HashSet::from([
                "hash-1".to_string(),
                "hash-2".to_string(),
                "hash-3".to_string(),
            ])),
        };

        {
            let _guard = PendingGuard::new(&inner, vec!["hash-1".to_string(), "hash-2".to_string()]);
            assert_eq!(inner.pending.lock().unwrap().len(), 3);
        }

        let remaining = inner.pending.lock().unwrap();
        assert_eq!(remaining.len(), 1);
        assert!(remaining.contains("hash-3"));
    }
}
