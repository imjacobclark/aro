//! Track identification: fingerprints a track (Chromaprint, via `rusty-chromaprint` —
//! pure Rust, no libchromaprint FFI/dylib needed), looks it up against the public
//! AcoustID service, and enriches it with canonical MusicBrainz metadata.
//!
//! This is a cache-on-query design, not a bulk mirror: nothing is downloaded ahead of
//! time. A background queue (see `queue`) identifies newly-scanned tracks without
//! blocking folder sync, and the same path serves manual per-track/per-album re-sync
//! requests triggered from the macOS app's context menu.

pub mod acoustid;
pub mod album;
#[cfg(test)]
mod characterization;
#[cfg(test)]
mod fixtures;
pub mod fingerprint;
pub mod loudness;
mod matching;
pub mod musicbrainz;
pub mod queue;
pub mod rate_limit;
pub mod tags;

pub use queue::{IdentificationConfig, IdentificationQueue, QueueStatus};

/// Bumped whenever a field is added to (or its meaning changes in) the response types this
/// crate caches raw — `acoustid::LookupResponse`/`Recording`/`ReleaseGroup` and
/// `musicbrainz::RecordingResponse`/`Release`/`ReleaseGroup`. A cached row whose
/// `schema_version` (see `aro_sync_store::IdentificationCacheEntry`) is below this is
/// re-fetched on next access rather than trusted, so a shape change doesn't silently starve
/// logic that depends on a field older cache entries never had a chance to capture.
///
/// History:
/// - `0`: pre-versioning. Includes every entry cached before this constant existed,
///   including ones cached before `musicbrainz::ReleaseGroup::id` was captured at all — the
///   original motivating case (see the removed `cached_response_has_release_group_ids`,
///   which this constant subsumes).
/// - `1`: `musicbrainz::ReleaseGroup::id` captured.
/// - `2`: `musicbrainz::Release::media` and `musicbrainz::ReleaseGroup::title` captured (the
///   `recording` lookup's `inc` gained `+media`) — group/tracklist matching depends on
///   `media` being present on every cached release stub, so an entry cached before this
///   crate requested it must be treated as stale like any other shape change.
pub const CACHE_SCHEMA_VERSION: u32 = 2;

/// Bumped whenever the *matching algorithm* changes in a way that could plausibly produce a
/// different, better answer for an already-identified file — e.g. a new tie-break in
/// `album::accept`, a reweighted `album::pair_score`. Distinct from
/// [`CACHE_SCHEMA_VERSION`], which tracks the *shape* of cached upstream responses, not this
/// crate's own decision logic. A row in `identification_results` whose
/// `resolution_generation` is below this is eligible for exactly one reconcile pass at the
/// current generation (see `queue`'s reconcile sweep) — each file is revisited at most once
/// per generation, which is what makes the sweep provably terminating rather than relying on
/// a heuristic stopping condition.
pub const IDENTIFICATION_GENERATION: u32 = 1;
