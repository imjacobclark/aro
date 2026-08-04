//! Batch matching of a folder's worth of files against one specific MusicBrainz release's
//! ordered tracklist, instead of resolving fingerprint -> recording -> release
//! independently per file (see `queue.rs`'s module doc for the per-file pipeline this
//! supplements).
//!
//! The per-file pipeline has a real ceiling: for some tracks, the recording actually linked
//! to the album the user owns simply isn't among AcoustID's candidate list for that
//! fingerprint at all (observed directly on real tracks). No amount of per-file ranking can
//! select a candidate that was never offered. Matching a whole folder against a release's
//! tracklist sidesteps that entirely: it decides "this file is track 9 of this specific
//! release" from position, duration, and title agreement across the *whole* group at once,
//! and doesn't require AcoustID to have pre-linked the right recording for any single file.
//!
//! Everything in this module is a pure function over already-fetched data — no I/O, no
//! store, no network client — so it's fully offline-testable against recorded fixtures (see
//! `fixtures`/`characterization`). The orchestration that actually gathers the inputs
//! (fetching releases, deciding which folder to group, persisting results) lives in
//! `queue.rs`.

use crate::{matching, musicbrainz, tags::ExistingTags};
use std::{
    cmp::Reverse,
    collections::{HashMap, HashSet},
    path::Path,
};

/// One file's evidence for group matching: `duration_secs` from the real decoded audio
/// (`fingerprint::FingerprintResult`) and `candidate_recording_ids` from the real AcoustID
/// response are independent, reliable ground truth; `tags` is the file's own existing tags
/// (weak, sometimes absent, sometimes wrong — see `ExistingTags`'s field docs).
#[derive(Debug, Clone, Copy)]
pub struct GroupFile<'a> {
    pub content_hash: &'a str,
    pub path: &'a Path,
    pub duration_secs: u32,
    pub tags: &'a ExistingTags,
    /// EVERY recording id AcoustID linked for this file's fingerprint, not just
    /// `acoustid::best_match`'s single pick — a candidate that lost the per-file ranking is
    /// still perfectly good evidence for "which release is this", since the per-file
    /// ranking only had title/artist to go on and this batch match has much more.
    pub candidate_recording_ids: &'a [String],
}

/// One file matched onto a specific track position within a candidate release.
#[derive(Debug, Clone)]
pub struct TrackAssignment {
    pub file_index: usize,
    pub medium_position: u32,
    pub track_position: u32,
    pub recording_id: String,
    pub title: String,
    pub track_artist: Option<String>,
    pub pair_score: f64,
}

/// The result of scoring one candidate release against a group of files.
#[derive(Debug, Clone)]
pub struct GroupMatch {
    pub release_id: String,
    pub release_title: Option<String>,
    pub release_group_id: Option<String>,
    pub release_artist: Option<String>,
    pub score: f64,
    pub assigned_fraction: f64,
    pub assignments: Vec<TrackAssignment>,
    /// Indices into the original `files` slice that scored below [`MIN_PAIR_SCORE`] against
    /// every track and were therefore left unassigned — never force-assigned onto a track
    /// just to fill a slot (see [`assign`]'s doc comment for why that matters).
    pub unmatched_files: Vec<usize>,
}

/// Cheap, no-fetch summary of one candidate release, built purely from the release *stubs*
/// already embedded in each file's recording lookup (see [`Medium`](musicbrainz::Medium)'s
/// doc comment) — this is what makes [`shortlist_candidates`] free.
struct ReleaseSummary {
    track_total: Option<u32>,
    is_album: bool,
    is_official: bool,
    affinity: i64,
}

/// A release needs to be offered by at least this many group files (or this fraction of the
/// group, whichever is larger) before it's even considered a candidate — filters out a
/// release one stray file happens to be linked to but the rest of the group has no relation
/// to.
const MIN_SHORTLIST_SUPPORT_FLOOR: usize = 2;
const MIN_SHORTLIST_SUPPORT_FRACTION: f64 = 0.15;

/// Ranks candidate releases for a group of files using only data already fetched for the
/// ordinary per-file recording lookups (`releases_per_file`) — no network call. This is
/// what satisfies the request-budget constraint for a group pass: shortlisting itself costs
/// nothing, so only the top `limit` candidates' full tracklists ever need fetching (by the
/// caller, via `musicbrainz::MusicBrainzClient::release`).
///
/// `releases_per_file[i]` is the full `.releases` list from `files[i]`'s own recording
/// lookup (i.e. every release any of that file's candidate recordings is linked to, not
/// just the winning one) — the union across all files is the candidate pool.
///
/// Ranking, most to least significant: **support** (how many distinct files offered this
/// *album*, counting every pressing of it as one — see [`title_class`]) descending;
/// **track-count agreement** with the group's size ascending (a
/// release stub without `media` track-count data sorts last on this term, not excluded);
/// **is-album** descending (reuses `musicbrainz::classify`, the same check
/// `select_release` uses, so the two paths never disagree); **affinity** (this artist's
/// consolidated evidence for the release-group, via `AffinityIndex`) descending;
/// **official status** descending; then release id ascending, purely so ties break the same
/// way on every run — determinism a later reconcile pass depends on.
pub fn shortlist_candidates(
    files: &[GroupFile<'_>],
    releases_per_file: &[Vec<musicbrainz::Release>],
    affinity: &musicbrainz::AffinityIndex,
    limit: usize,
) -> Vec<String> {
    let mut support: HashMap<String, usize> = HashMap::new();
    let mut summary: HashMap<String, ReleaseSummary> = HashMap::new();
    let mut releases_in_class: HashMap<String, HashSet<String>> = HashMap::new();

    for releases in releases_per_file {
        let mut seen_in_this_file: HashSet<String> = HashSet::new();
        for release in releases {
            let class = title_class(release);
            releases_in_class
                .entry(class.clone())
                .or_default()
                .insert(release.id.clone());
            // Support counts *files*, so a file offering three pressings of one album is
            // one voice for that album rather than three.
            if seen_in_this_file.insert(class.clone()) {
                *support.entry(class).or_insert(0) += 1;
            }
            summary.entry(release.id.clone()).or_insert_with(|| {
                let group = release.release_group.as_ref();
                ReleaseSummary {
                    track_total: release
                        .media
                        .iter()
                        .filter_map(|medium| medium.track_count)
                        .max(),
                    is_album: group.map(musicbrainz::classify)
                        == Some(musicbrainz::ReleaseGroupKind::Album),
                    is_official: release.status.as_deref() == Some("Official"),
                    affinity: group
                        .and_then(|group| group.id.as_deref())
                        .map(|id| affinity.count(id))
                        .unwrap_or(0),
                }
            });
        }
    }

    let member_count = files.len();
    let threshold = ((MIN_SHORTLIST_SUPPORT_FRACTION * member_count as f64).ceil() as usize)
        .max(MIN_SHORTLIST_SUPPORT_FLOOR);
    let rank_of = |release_id: &str| {
        let info = &summary[release_id];
        let track_total_diff = info
            .track_total
            .map(|total| (i64::from(total) - member_count as i64).unsigned_abs() as u32)
            .unwrap_or(u32::MAX);
        (
            track_total_diff,
            Reverse(info.is_album),
            Reverse(info.affinity),
            Reverse(info.is_official),
            release_id.to_owned(),
        )
    };

    // One release per class actually gets its tracklist fetched: the pressing whose track
    // count best fits this folder. Picking within the class rather than across the whole
    // pool is what stops a 31-track compilation from representing a 15-track album.
    let mut candidates: Vec<(String, usize)> = support
        .into_iter()
        .filter(|(_, count)| *count >= threshold)
        .filter_map(|(class, count)| {
            let representative = releases_in_class
                .get(&class)?
                .iter()
                .min_by_key(|release_id| rank_of(release_id))?
                .clone();
            Some((representative, count))
        })
        .collect();

    candidates.sort_by_key(|(release_id, count)| (Reverse(*count), rank_of(release_id)));

    candidates
        .into_iter()
        .take(limit)
        .map(|(release_id, _)| release_id)
        .collect()
}

/// Groups pressings of the same album together for support counting. MusicBrainz routinely
/// carries one album as many release ids — nine separate "Greatest Hits" pressings for The
/// Shadows, observed directly — and counting each separately splits an album's support
/// until it drops under the shortlist threshold, handing the folder to whichever unrelated
/// compilation happens to exist as a single release. This mirrors what `AffinityIndex`
/// already does for affinity, so the two tiers agree on what counts as "the same album".
///
/// Keyed on release-group id when the titles agree, so two genuinely different albums that
/// happen to share a title (a self-titled record and a compilation of it) stay distinct.
/// A release with no usable title falls back to its own id and stays a singleton class.
fn title_class(release: &musicbrainz::Release) -> String {
    let group = release.release_group.as_ref();
    let title = group
        .and_then(|group| group.title.as_deref())
        .or(release.title.as_deref())
        .map(matching::normalize_matching_key)
        .filter(|title| !title.is_empty());
    match title {
        // NUL cannot appear in a real MusicBrainz title, so this never collides with one.
        Some(title) => title,
        None => format!("\0untitled:{}", release.id),
    }
}

/// A pair scores below this are never assigned, regardless of whether a track slot is
/// still free — an unmatched file falls back to the per-file pipeline instead (see
/// `queue.rs::identify_group`), rather than being forced onto the least-bad remaining track.
const MIN_PAIR_SCORE: f64 = 0.55;
/// Duration difference (ms) within which two durations are treated as an exact match.
/// `fingerprint::fingerprint_file` floors `total_frames / sample_rate`, so up to ~1s is
/// inherent quantization; different masterings/fades commonly add 1-3s on top.
const DURATION_EXACT_TOLERANCE_MS: i64 = 4_000;
/// Duration difference (ms) at or beyond which the duration term scores zero — beyond this,
/// two files are very unlikely to be the same recording.
const DURATION_ZERO_TOLERANCE_MS: i64 = 15_000;
const RECORDING_WEIGHT: f64 = 0.45;
const DURATION_WEIGHT: f64 = 0.30;
const TITLE_WEIGHT: f64 = 0.20;
/// Weight is deliberately tiny: compilation rips routinely carry the *original* album's
/// track numbering rather than the compilation's, so a mismatch here is weak evidence at
/// best and a match is only a tie-break, not a determining signal.
const POSITION_WEIGHT: f64 = 0.05;

/// Scores one (file, track) pair in `[0.0, 1.0]`. Each term contributes only when it has
/// evidence to contribute (e.g. a track with no `length` doesn't count the duration term at
/// all, rather than penalizing the pair for missing data); the weighted sum is renormalized
/// over just the terms that fired, so a release with sparse metadata isn't systematically
/// penalized relative to one with complete metadata.
fn pair_score(
    file: &GroupFile<'_>,
    medium: &musicbrainz::Medium,
    track: &musicbrainz::Track,
) -> f64 {
    let mut weighted_sum = 0.0;
    let mut weight_total = 0.0;

    // Always has evidence whenever the file has any candidates at all -- a track with no
    // recording linked (or one that isn't among the file's candidates) genuinely scores 0
    // here, it isn't treated as "no evidence".
    if !file.candidate_recording_ids.is_empty() {
        let matches = track.recording.as_ref().is_some_and(|recording| {
            file.candidate_recording_ids
                .iter()
                .any(|id| id == &recording.id)
        });
        weighted_sum += RECORDING_WEIGHT * if matches { 1.0 } else { 0.0 };
        weight_total += RECORDING_WEIGHT;
    }

    if let Some(length_ms) = track.length {
        let file_ms = i64::from(file.duration_secs) * 1_000;
        let diff = (file_ms - length_ms as i64).abs();
        let score = if diff <= DURATION_EXACT_TOLERANCE_MS {
            1.0
        } else {
            let span = (DURATION_ZERO_TOLERANCE_MS - DURATION_EXACT_TOLERANCE_MS) as f64;
            (1.0 - (diff - DURATION_EXACT_TOLERANCE_MS) as f64 / span).max(0.0)
        };
        weighted_sum += DURATION_WEIGHT * score;
        weight_total += DURATION_WEIGHT;
    }

    if let (Some(file_title), Some(track_title)) =
        (file.tags.title.as_deref(), track.title.as_deref())
    {
        weighted_sum += TITLE_WEIGHT * matching::title_similarity(file_title, track_title);
        weight_total += TITLE_WEIGHT;
    }

    if let (Some(file_track_number), Some(track_position)) =
        (file.tags.track_number, track.position)
    {
        let disc_agrees =
            file.tags.disc_number.is_none() || file.tags.disc_number == medium.position;
        let matches = file_track_number == track_position && disc_agrees;
        weighted_sum += POSITION_WEIGHT * if matches { 1.0 } else { 0.0 };
        weight_total += POSITION_WEIGHT;
    }

    if weight_total == 0.0 {
        return 0.0;
    }
    weighted_sum / weight_total
}

struct Candidate<'r> {
    file_index: usize,
    medium_position: u32,
    track: &'r musicbrainz::Track,
    score: f64,
}

/// Scores every group file against every track of `release` and assigns files to tracks —
/// see [`assign`] for the assignment strategy. `release` should come from
/// `musicbrainz::MusicBrainzClient::release`, not a release *stub*: only a full fetch
/// carries a nested recording id per track (verified directly — a recording lookup's
/// embedded release stub does not, even with `+media`).
pub fn match_group_against_release(
    files: &[GroupFile<'_>],
    release: &musicbrainz::ReleaseResponse,
) -> GroupMatch {
    let mut candidates = Vec::new();
    for medium in &release.media {
        let medium_position = medium.position.unwrap_or(1);
        for track in &medium.tracks {
            if track.position.is_none() {
                // Can't be placed in a specific assignment slot without a position.
                continue;
            }
            for (file_index, file) in files.iter().enumerate() {
                candidates.push(Candidate {
                    file_index,
                    medium_position,
                    track,
                    score: pair_score(file, medium, track),
                });
            }
        }
    }

    let assignments = assign(candidates);
    let assigned_files: HashSet<usize> = assignments.iter().map(|a| a.file_index).collect();
    let unmatched_files: Vec<usize> = (0..files.len())
        .filter(|index| !assigned_files.contains(index))
        .collect();

    let assigned_fraction = if files.is_empty() {
        0.0
    } else {
        assignments.len() as f64 / files.len() as f64
    };
    let mean_assigned_score = if assignments.is_empty() {
        0.0
    } else {
        assignments.iter().map(|a| a.pair_score).sum::<f64>() / assignments.len() as f64
    };
    let release_track_total: usize = release.media.iter().map(|medium| medium.tracks.len()).sum();
    let track_count_agreement = if release_track_total == 0 && files.is_empty() {
        1.0
    } else {
        let denominator = release_track_total.max(files.len()) as f64;
        1.0 - (release_track_total as f64 - files.len() as f64).abs() / denominator
    };

    let score =
        0.55 * assigned_fraction + 0.30 * mean_assigned_score + 0.15 * track_count_agreement;

    GroupMatch {
        release_id: release.id.clone(),
        release_title: release.title.clone(),
        release_group_id: release
            .release_group
            .as_ref()
            .and_then(|group| group.id.clone()),
        release_artist: release
            .artist_credit
            .first()
            .and_then(|credit| credit.name.clone()),
        score,
        assigned_fraction,
        assignments,
        unmatched_files,
    }
}

/// Greedy assignment over every (file, track) pair sorted globally by score — not per-file
/// greedy. Sorting all pairs once and walking them in order, taking a pair only if neither
/// its file nor its track slot is already used, makes the result one-to-one *by
/// construction*: a track can never be claimed twice and a file can never be assigned
/// twice, with no extra bookkeeping needed to enforce it. Per-file greedy (pick each file's
/// best track independently) would not have this property -- two files could easily claim
/// the same track.
///
/// This is greedy maximal bipartite matching, not a globally optimal (Hungarian) matching.
/// That's a deliberate trade: the dominant term in `pair_score` (recording id, weight 0.45)
/// is near-always unique per track when it has evidence at all, so the cases where greedy
/// diverges from optimal require two files with near-identical durations, no recording
/// evidence, and indistinguishable titles -- a narrow edge case, not the common one. If real
/// data shows swapped pairs in practice, the fix is a hand-rolled Hungarian algorithm
/// (~80 lines), not a new dependency.
///
/// Ties break by higher score, then lower track position, then lower file index -- fully
/// deterministic, which is what lets a reconcile pass compare two runs byte-for-byte.
fn assign(mut candidates: Vec<Candidate<'_>>) -> Vec<TrackAssignment> {
    candidates.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.track.position.cmp(&b.track.position))
            .then_with(|| a.file_index.cmp(&b.file_index))
    });

    let mut used_files = HashSet::new();
    let mut used_tracks = HashSet::new();
    let mut assignments = Vec::new();

    for candidate in candidates {
        if candidate.score < MIN_PAIR_SCORE {
            continue;
        }
        if used_files.contains(&candidate.file_index) {
            continue;
        }
        // `track.position` is `Some` for every candidate here -- tracks without a position
        // were filtered out before `Candidate`s were built.
        let track_position = candidate.track.position.expect("filtered by caller");
        let track_key = (candidate.medium_position, track_position);
        if used_tracks.contains(&track_key) {
            continue;
        }

        used_files.insert(candidate.file_index);
        used_tracks.insert(track_key);

        let recording_id = candidate
            .track
            .recording
            .as_ref()
            .map(|recording| recording.id.clone())
            .unwrap_or_default();
        let track_artist = candidate
            .track
            .recording
            .as_ref()
            .and_then(|recording| recording.artist_credit.first())
            .and_then(|credit| credit.name.clone());

        assignments.push(TrackAssignment {
            file_index: candidate.file_index,
            medium_position: candidate.medium_position,
            track_position,
            recording_id,
            title: candidate.track.title.clone().unwrap_or_default(),
            track_artist,
            pair_score: candidate.score,
        });
    }

    assignments
}

const MIN_ASSIGNED_FRACTION: f64 = 0.75;
const MIN_GROUP_SCORE: f64 = 0.70;
/// How much better the best candidate must score than the runner-up before the match is
/// trusted as unambiguous -- unless they share a release-group id (see below).
const MIN_RUNNER_UP_MARGIN: f64 = 0.05;

/// Whether `best` should be accepted as the group's release. `group_size` is the number of
/// files actually being matched (not `best.assignments.len()`), so a rejected match can be
/// told apart from "there was only ever one file to match".
///
/// For `group_size == 1` (a single manually re-synced file, matched only because sibling
/// consensus injected a candidate -- see `queue.rs::identify_group`), the sibling-consensus
/// requirement itself is enforced by the caller, not here: this function only checks that
/// the one pair scored well enough.
///
/// For `group_size >= 2`: requires most of the group to have been placed
/// (`assigned_fraction`), a solid overall score, at least two actual assignments (so two
/// files agreeing isn't dismissed as "not really a group"), and -- if there's a runner-up
/// candidate at all -- either a clear score margin over it or that the two candidates share
/// a release-group id. The release-group escape matters: two MusicBrainz releases of the
/// same album (a UK/US pressing, a remaster) are not a real ambiguity about which *album*
/// this is, and must not cause an otherwise-clear match to be rejected as ambiguous.
pub fn accept(best: &GroupMatch, runner_up: Option<&GroupMatch>, group_size: usize) -> bool {
    if group_size == 0 {
        return false;
    }
    if group_size == 1 {
        return best.assignments.len() == 1 && best.score >= MIN_GROUP_SCORE;
    }
    if best.assigned_fraction < MIN_ASSIGNED_FRACTION
        || best.score < MIN_GROUP_SCORE
        || best.assignments.len() < 2
    {
        return false;
    }
    match runner_up {
        None => true,
        Some(runner_up) => {
            let same_release_group = best.release_group_id.is_some()
                && best.release_group_id == runner_up.release_group_id;
            best.score - runner_up.score >= MIN_RUNNER_UP_MARGIN || same_release_group
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;
    use std::path::PathBuf;

    /// Owns the data a [`GroupFile`] only borrows, so a fixture's files can be materialized
    /// once per test and referenced for its lifetime.
    struct OwnedGroupFile {
        path: PathBuf,
        duration_secs: u32,
        tags: ExistingTags,
        candidate_recording_ids: Vec<String>,
    }

    fn owned_files_from_fixture(name: &str) -> Vec<OwnedGroupFile> {
        fixtures::group(name)
            .files
            .into_iter()
            .map(|file| OwnedGroupFile {
                path: PathBuf::from(file.file_name),
                duration_secs: file.duration_secs.unwrap_or(0),
                tags: ExistingTags {
                    title: file.tag_title,
                    track_number: file.tag_track_number,
                    ..Default::default()
                },
                candidate_recording_ids: file.candidate_recording_ids,
            })
            .collect()
    }

    fn borrow_group_files(owned: &[OwnedGroupFile]) -> Vec<GroupFile<'_>> {
        owned
            .iter()
            .map(|file| GroupFile {
                content_hash: "unused-in-tests",
                path: &file.path,
                duration_secs: file.duration_secs,
                tags: &file.tags,
                candidate_recording_ids: &file.candidate_recording_ids,
            })
            .collect()
    }

    fn duplicate_track_positions(assignments: &[TrackAssignment]) -> usize {
        let mut seen = HashSet::new();
        let mut duplicates = 0;
        for assignment in assignments {
            if !seen.insert((assignment.medium_position, assignment.track_position)) {
                duplicates += 1;
            }
        }
        duplicates
    }

    /// The motivating real case: 27 files, each independently ambiguous under the per-file
    /// pipeline (see `characterization::december_neck_deep_falls_back_to_first_match...`
    /// for the shape of that ambiguity), converge on the correct release when matched as a
    /// batch against its real tracklist -- validated against real captured data before any
    /// of this module was written.
    #[test]
    fn beatles_1_folder_converges_on_a_single_release() {
        let owned = owned_files_from_fixture("beatles-1");
        let files = borrow_group_files(&owned);
        let release = fixtures::mb_release("beatles-1");

        let result = match_group_against_release(&files, &release);

        assert_eq!(result.assignments.len(), 27);
        assert!(result.unmatched_files.is_empty());
        assert_eq!(duplicate_track_positions(&result.assignments), 0);
        assert!(
            result.score > 0.95,
            "expected a near-perfect score, got {}",
            result.score
        );
        assert!(accept(&result, None, files.len()));
    }

    #[test]
    fn blink_182_greatest_hits_folder_converges_on_a_single_release() {
        let owned = owned_files_from_fixture("blink-182-greatest-hits");
        let files = borrow_group_files(&owned);
        let release = fixtures::mb_release("blink-182-greatest-hits");

        let result = match_group_against_release(&files, &release);

        assert_eq!(result.assignments.len(), 19);
        assert_eq!(duplicate_track_positions(&result.assignments), 0);
        assert!(accept(&result, None, files.len()));
    }

    /// Must-not-regress case: this folder already resolves correctly under the per-file
    /// pipeline (see the corrected ground truth in the session's plan -- Arctic Monkeys
    /// legitimately owns three distinct albums, one per folder). Group matching must not
    /// disturb that.
    #[test]
    fn arctic_monkeys_am_folder_converges_on_a_single_release() {
        let owned = owned_files_from_fixture("arctic-monkeys-am");
        let files = borrow_group_files(&owned);
        let release = fixtures::mb_release("arctic-monkeys-am");

        let result = match_group_against_release(&files, &release);

        assert_eq!(result.assignments.len(), 12);
        assert_eq!(duplicate_track_positions(&result.assignments), 0);
        assert!(accept(&result, None, files.len()));
    }

    /// The real Neck Deep case: one file in the folder ("Citizens Of Earth copy") doesn't
    /// belong on this release at all and must be left unmatched rather than forced onto
    /// whichever track has the least-bad remaining score.
    #[test]
    fn leftover_file_is_unmatched_not_force_assigned() {
        let owned = owned_files_from_fixture("neck-deep-lifes-not-out-to-get-you");
        let files = borrow_group_files(&owned);
        let release = fixtures::mb_release("neck-deep-lifes-not-out-to-get-you");

        let result = match_group_against_release(&files, &release);

        assert_eq!(result.unmatched_files.len(), 1);
        assert_eq!(result.assignments.len(), files.len() - 1);
        assert_eq!(duplicate_track_positions(&result.assignments), 0);
        assert!(accept(&result, None, files.len()));
    }

    /// A folder assembled from fragments of two unrelated real albums must not converge on
    /// either one -- only 2 of 5 files in the mixed bag actually belong to "1", so
    /// `assigned_fraction` (0.4) falls well short of the acceptance threshold.
    #[test]
    fn mixed_bag_folder_is_rejected() {
        let owned = owned_files_from_fixture("mixed-bag");
        let files = borrow_group_files(&owned);
        let release = fixtures::mb_release("beatles-1");

        let result = match_group_against_release(&files, &release);

        assert!(!accept(&result, None, files.len()));
    }

    /// Running the same inputs through `match_group_against_release` twice must produce a
    /// byte-for-byte identical result -- the foundation a later reconcile pass depends on to
    /// know a re-run revised nothing.
    #[test]
    fn matching_is_deterministic_across_runs() {
        let owned = owned_files_from_fixture("beatles-1");
        let files = borrow_group_files(&owned);
        let release = fixtures::mb_release("beatles-1");

        let first = match_group_against_release(&files, &release);
        let second = match_group_against_release(&files, &release);

        assert_eq!(first.score, second.score);
        assert_eq!(first.assignments.len(), second.assignments.len());
        for (a, b) in first.assignments.iter().zip(second.assignments.iter()) {
            assert_eq!(a.file_index, b.file_index);
            assert_eq!(a.track_position, b.track_position);
            assert_eq!(a.recording_id, b.recording_id);
            assert_eq!(a.pair_score, b.pair_score);
        }
    }

    fn synthetic_track(
        id: &str,
        position: u32,
        title: &str,
        length_ms: Option<u64>,
    ) -> musicbrainz::Track {
        musicbrainz::Track {
            id: id.to_string(),
            position: Some(position),
            number: Some(position.to_string()),
            title: Some(title.to_string()),
            length: length_ms,
            recording: Some(musicbrainz::TrackRecording {
                id: id.to_string(),
                title: Some(title.to_string()),
                length: length_ms,
                artist_credit: Vec::new(),
            }),
        }
    }

    fn synthetic_release(
        id: &str,
        tracks: Vec<musicbrainz::Track>,
    ) -> musicbrainz::ReleaseResponse {
        let track_count = tracks.len() as u32;
        musicbrainz::ReleaseResponse {
            id: id.to_string(),
            title: Some(id.to_string()),
            status: Some("Official".to_string()),
            artist_credit: Vec::new(),
            release_group: None,
            media: vec![musicbrainz::Medium {
                position: Some(1),
                track_count: Some(track_count),
                track_offset: Some(0),
                format: None,
                tracks,
            }],
        }
    }

    /// Two files with identical duration and no recording-id evidence at all must still
    /// land on two *different* tracks, not both on whichever track scores best in
    /// isolation -- the property greedy-over-globally-sorted-pairs assignment guarantees by
    /// construction.
    #[test]
    fn assignment_is_one_to_one_for_identical_durations() {
        let tags_a = ExistingTags {
            title: Some("Song A".into()),
            ..Default::default()
        };
        let tags_b = ExistingTags {
            title: Some("Song B".into()),
            ..Default::default()
        };
        let empty_candidates: Vec<String> = Vec::new();
        let files = vec![
            GroupFile {
                content_hash: "a",
                path: Path::new("a.mp3"),
                duration_secs: 200,
                tags: &tags_a,
                candidate_recording_ids: &empty_candidates,
            },
            GroupFile {
                content_hash: "b",
                path: Path::new("b.mp3"),
                duration_secs: 200,
                tags: &tags_b,
                candidate_recording_ids: &empty_candidates,
            },
        ];
        let release = synthetic_release(
            "rel-1",
            vec![
                synthetic_track("rec-1", 1, "Song A", Some(200_000)),
                synthetic_track("rec-2", 2, "Song B", Some(200_000)),
            ],
        );

        let result = match_group_against_release(&files, &release);

        assert_eq!(result.assignments.len(), 2);
        assert_eq!(duplicate_track_positions(&result.assignments), 0);
    }

    /// When neither the release nor any file carries duration data, the duration term
    /// contributes no evidence and the remaining terms are renormalized over their own
    /// weight -- a sparse-metadata release isn't systematically penalized relative to a
    /// complete one.
    #[test]
    fn release_without_track_lengths_still_matches_on_recording_ids() {
        let tags = ExistingTags::default();
        let candidates = vec!["rec-1".to_string()];
        let files = vec![GroupFile {
            content_hash: "a",
            path: Path::new("a.mp3"),
            duration_secs: 200,
            tags: &tags,
            candidate_recording_ids: &candidates,
        }];
        let release = synthetic_release("rel-1", vec![synthetic_track("rec-1", 1, "Song A", None)]);

        let result = match_group_against_release(&files, &release);

        assert_eq!(result.assignments.len(), 1);
        assert_eq!(result.assignments[0].pair_score, 1.0);
    }

    fn synthetic_match(
        release_id: &str,
        release_group_id: Option<&str>,
        score: f64,
        assigned: usize,
    ) -> GroupMatch {
        GroupMatch {
            release_id: release_id.to_string(),
            release_title: None,
            release_group_id: release_group_id.map(str::to_string),
            release_artist: None,
            score,
            assigned_fraction: 1.0,
            assignments: (0..assigned)
                .map(|index| TrackAssignment {
                    file_index: index,
                    medium_position: 1,
                    track_position: index as u32 + 1,
                    recording_id: format!("rec-{index}"),
                    title: format!("Track {index}"),
                    track_artist: None,
                    pair_score: score,
                })
                .collect(),
            unmatched_files: Vec::new(),
        }
    }

    #[test]
    fn runner_up_within_margin_is_rejected_as_ambiguous() {
        let best = synthetic_match("rel-a", Some("rg-a"), 0.80, 4);
        let runner_up = synthetic_match("rel-b", Some("rg-b"), 0.78, 4);

        assert!(!accept(&best, Some(&runner_up), 4));
    }

    #[test]
    fn runner_up_within_margin_is_accepted_when_same_release_group() {
        let best = synthetic_match("rel-a", Some("rg-shared"), 0.80, 4);
        let runner_up = synthetic_match("rel-b", Some("rg-shared"), 0.78, 4);

        assert!(accept(&best, Some(&runner_up), 4));
    }

    #[test]
    fn runner_up_beyond_margin_is_accepted() {
        let best = synthetic_match("rel-a", Some("rg-a"), 0.90, 4);
        let runner_up = synthetic_match("rel-b", Some("rg-b"), 0.70, 4);

        assert!(accept(&best, Some(&runner_up), 4));
    }

    #[test]
    fn low_assigned_fraction_is_rejected_regardless_of_score() {
        let mut poor_coverage = synthetic_match("rel-a", None, 0.95, 4);
        poor_coverage.assigned_fraction = 0.5;

        assert!(!accept(&poor_coverage, None, 8));
    }

    #[test]
    fn single_file_group_requires_a_high_score() {
        let weak = synthetic_match("rel-a", None, 0.60, 1);
        let strong = synthetic_match("rel-a", None, 0.75, 1);

        assert!(!accept(&weak, None, 1));
        assert!(accept(&strong, None, 1));
    }

    /// As [`synthetic_stub_release`], but with a release-group *title* — what
    /// [`title_class`] groups pressings by.
    fn titled_stub_release(
        id: &str,
        group_id: &str,
        group_title: &str,
        track_total: u32,
    ) -> musicbrainz::Release {
        let mut release = synthetic_stub_release(id, Some(group_id), Some(track_total));
        if let Some(group) = release.release_group.as_mut() {
            group.title = Some(group_title.to_string());
        }
        release
    }

    /// The real shape of The Shadows' "Greatest Hits" folder: MusicBrainz carries that
    /// album as nine separate pressings, while an unrelated compilation exists as a
    /// single release. Counting support per release id split the album nine ways —
    /// every pressing landed under the threshold and the folder was handed to the
    /// compilation, which is how 13 tracks ended up filed as "Shadows Are Go!".
    #[test]
    fn pressings_of_one_album_are_counted_together_not_split_apart() {
        let releases_per_file: Vec<Vec<musicbrainz::Release>> = (0..15)
            .map(|file_index| {
                let mut releases = Vec::new();
                if file_index < 9 {
                    // Each file offers a *different* pressing of the same album, so no
                    // single release id gets more than one voice.
                    releases.push(titled_stub_release(
                        &format!("rel-greatest-hits-{file_index}"),
                        &format!("rg-greatest-hits-{file_index}"),
                        "Greatest Hits",
                        17,
                    ));
                }
                if file_index < 5 {
                    releases.push(titled_stub_release(
                        "rel-30-all-time",
                        "rg-30-all-time",
                        "30 All Time Greatest Hits",
                        31,
                    ));
                }
                releases
            })
            .collect();
        let owned: Vec<OwnedGroupFile> = (0..15)
            .map(|_| OwnedGroupFile {
                path: PathBuf::from("f.mp3"),
                duration_secs: 200,
                tags: ExistingTags::default(),
                candidate_recording_ids: Vec::new(),
            })
            .collect();
        let files = borrow_group_files(&owned);

        let shortlisted = shortlist_candidates(
            &files,
            &releases_per_file,
            &musicbrainz::AffinityIndex::default(),
            3,
        );

        assert!(
            shortlisted
                .first()
                .is_some_and(|id| id.starts_with("rel-greatest-hits-")),
            "the album nine files agree on should outrank the compilation five do, got {shortlisted:?}"
        );
        // One pressing represents the album; the others must not crowd out the limited
        // tracklist-fetch budget with duplicates of the same record.
        assert_eq!(
            shortlisted
                .iter()
                .filter(|id| id.starts_with("rel-greatest-hits-"))
                .count(),
            1,
            "expected a single representative pressing, got {shortlisted:?}"
        );
    }

    fn synthetic_stub_release(
        id: &str,
        group_id: Option<&str>,
        track_total: Option<u32>,
    ) -> musicbrainz::Release {
        musicbrainz::Release {
            id: id.to_string(),
            title: Some(id.to_string()),
            status: Some("Official".to_string()),
            release_group: group_id.map(|group_id| musicbrainz::ReleaseGroup {
                id: Some(group_id.to_string()),
                primary_type: Some("Album".to_string()),
                secondary_types: Vec::new(),
                title: None,
            }),
            media: track_total
                .map(|total| {
                    vec![musicbrainz::Medium {
                        position: Some(1),
                        track_count: Some(total),
                        track_offset: Some(0),
                        format: None,
                        tracks: Vec::new(),
                    }]
                })
                .unwrap_or_default(),
        }
    }

    #[test]
    fn shortlist_never_exceeds_the_fetch_limit() {
        // Five files, four different releases each offered by at least two files.
        let releases_per_file: Vec<Vec<musicbrainz::Release>> = (0..5)
            .map(|file_index| {
                vec![
                    synthetic_stub_release("rel-a", Some("rg-a"), Some(5)),
                    synthetic_stub_release("rel-b", Some("rg-b"), Some(5)),
                    synthetic_stub_release("rel-c", Some("rg-c"), Some(5)),
                    synthetic_stub_release(&format!("rel-unique-{file_index}"), None, None),
                ]
            })
            .collect();
        let owned: Vec<OwnedGroupFile> = (0..5)
            .map(|_| OwnedGroupFile {
                path: PathBuf::from("f.mp3"),
                duration_secs: 200,
                tags: ExistingTags::default(),
                candidate_recording_ids: Vec::new(),
            })
            .collect();
        let files = borrow_group_files(&owned);

        let shortlisted = shortlist_candidates(
            &files,
            &releases_per_file,
            &musicbrainz::AffinityIndex::default(),
            2,
        );

        assert!(shortlisted.len() <= 2);
    }

    #[test]
    fn shortlist_drops_low_support_releases() {
        // "rel-popular" is offered by every file; "rel-rare" only by one -- below the
        // support threshold for a 5-file group (max(2, ceil(0.15*5)) = 2).
        let releases_per_file: Vec<Vec<musicbrainz::Release>> = (0..5)
            .map(|file_index| {
                let mut releases = vec![synthetic_stub_release(
                    "rel-popular",
                    Some("rg-pop"),
                    Some(5),
                )];
                if file_index == 0 {
                    releases.push(synthetic_stub_release("rel-rare", Some("rg-rare"), Some(5)));
                }
                releases
            })
            .collect();
        let owned: Vec<OwnedGroupFile> = (0..5)
            .map(|_| OwnedGroupFile {
                path: PathBuf::from("f.mp3"),
                duration_secs: 200,
                tags: ExistingTags::default(),
                candidate_recording_ids: Vec::new(),
            })
            .collect();
        let files = borrow_group_files(&owned);

        let shortlisted = shortlist_candidates(
            &files,
            &releases_per_file,
            &musicbrainz::AffinityIndex::default(),
            5,
        );

        assert_eq!(shortlisted, vec!["rel-popular".to_string()]);
    }
}
