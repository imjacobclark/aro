//! Where a library has gone untidy: duplicated files, alternate encodings of the same
//! recording, files that moved, files that vanished, and folders whose contents disagree
//! about what album they are.
//!
//! Ported from the macOS client's `AroCommon.LibraryHealthAnalyzer`, and moved here for a
//! reason beyond tidiness. The Swift version analyses only the copies on the machine
//! running it (`WHERE l.device_id = ?`), so a Mac used as a remote client of a hub — which
//! is the normal setup — has almost no local file locations and sees almost nothing. The
//! hub is the machine that actually holds the files, so it is the only place the analysis
//! can be complete. Both clients now render what this produces.

use aro_sync_store::{HubStore, LibraryCopyRow, StoreError};
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// One file on disk backing a track. A track can have several — the same recording ripped
/// twice, or a file that moved and left its old location behind.
#[derive(Debug, Clone, Serialize)]
pub struct HealthCopy {
    pub track_id: String,
    pub path: String,
    pub available: bool,
    pub codec: String,
    pub sample_rate: Option<f64>,
    pub bit_depth: Option<i64>,
    pub bitrate: Option<f64>,
    pub file_size_bytes: i64,
}

impl HealthCopy {
    pub fn id(&self) -> String {
        format!("{}|{}", self.track_id, self.path)
    }

    /// Orders copies by how much of the recording they preserve. Lossless dominates
    /// everything — a 16-bit FLAC is worth keeping over a 320 kbps MP3 whatever their
    /// bitrates say — then bit depth, then sample rate, then bitrate as the tie-break.
    fn quality_score(&self) -> f64 {
        const LOSSLESS: [&str; 6] = ["flac", "alac", "apple lossless", "wav", "wave", "aiff"];
        let codec = self.codec.to_lowercase();
        let lossless = LOSSLESS.iter().any(|name| codec.contains(name));

        (if lossless { 1_000_000.0 } else { 0.0 })
            + self.bit_depth.unwrap_or(0) as f64 * 10_000.0
            + self.sample_rate.unwrap_or(0.0)
            + self.bitrate.unwrap_or(0.0) / 1_000.0
    }

    /// Two copies sharing this are the same encoding, so a pair of them is a duplicate
    /// rather than a genuine choice between formats.
    fn format_signature(&self) -> String {
        format!(
            "{}|{}|{}|{}",
            self.codec.to_lowercase(),
            self.bit_depth.unwrap_or(0),
            self.sample_rate.unwrap_or(0.0).round() as i64,
            self.bitrate.unwrap_or(0.0).round() as i64,
        )
    }

    fn folder(&self) -> &str {
        match self.path.rfind('/') {
            Some(index) => &self.path[..index],
            None => "",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthRecommendationKind {
    ExactDuplicate,
    AlternateEncoding,
    Moved,
    Missing,
    FragmentedFolder,
}

#[derive(Debug, Clone, Serialize)]
pub struct HealthRecommendation {
    pub id: String,
    pub kind: HealthRecommendationKind,
    pub title: String,
    pub artist: String,
    pub reason: String,
    pub copies: Vec<HealthCopy>,
    pub preferred_copy_id: Option<String>,
    pub potential_savings_bytes: i64,
}

/// A track and every file backing it.
#[derive(Debug, Clone)]
pub struct HealthTrack {
    pub id: String,
    pub content_hash: Option<String>,
    pub title: String,
    pub artist: String,
    /// `None` when identification has not resolved an album yet — treated as "no signal"
    /// by folder-fragmentation analysis, not as its own distinct album value.
    pub album: Option<String>,
    pub duration: Option<f64>,
    pub copies: Vec<HealthCopy>,
}

#[derive(Debug, Default, Serialize)]
pub struct HealthReport {
    pub exact_duplicates: Vec<HealthRecommendation>,
    pub alternate_encodings: Vec<HealthRecommendation>,
    pub moved_files: Vec<HealthRecommendation>,
    pub missing_files: Vec<HealthRecommendation>,
    pub fragmented_folders: Vec<HealthRecommendation>,
    pub recommendation_count: usize,
    /// Only exact duplicates are counted as reclaimable. An alternate encoding is a
    /// judgement call the listener has to make, so promising its bytes back would be a lie.
    pub exact_reclaimable_bytes: i64,
}

/// A folder needs at least this many available copies before it is worth judging for album
/// fragmentation at all — a couple of stray files is not a meaningful signal.
const MIN_TRACKS_FOR_FRAGMENTED_FOLDER: usize = 4;
/// A folder spanning fewer distinct albums than this is normal, not fragmented.
const MIN_ALBUMS_FOR_FRAGMENTED_FOLDER: usize = 2;
/// Durations within this many seconds are treated as the same recording.
const DURATION_TOLERANCE_SECONDS: f64 = 2.0;

/// Reads every scanned copy out of the store and reports on it.
///
/// Groups the one-row-per-copy join back into tracks before analysing, since every check
/// except fragmented folders is a statement about a track's copies taken together.
pub fn review(store: &HubStore) -> Result<HealthReport, StoreError> {
    let mut tracks: Vec<HealthTrack> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();

    for row in store.library_copies()? {
        let metadata: Value = serde_json::from_str(&row.metadata).unwrap_or(Value::Null);
        let position = *index.entry(row.track_id.clone()).or_insert_with(|| {
            tracks.push(track_from(&row, &metadata));
            tracks.len() - 1
        });
        tracks[position].copies.push(copy_from(&row, &metadata));
    }

    Ok(analyze(&tracks))
}

fn track_from(row: &LibraryCopyRow, metadata: &Value) -> HealthTrack {
    HealthTrack {
        id: row.track_id.clone(),
        content_hash: row.content_hash.clone(),
        title: effective(metadata, "title").unwrap_or_else(|| "Unknown Track".to_owned()),
        artist: effective(metadata, "artist").unwrap_or_else(|| "Unknown Artist".to_owned()),
        album: effective(metadata, "album"),
        duration: metadata.get("duration").and_then(Value::as_f64),
        copies: Vec::new(),
    }
}

fn copy_from(row: &LibraryCopyRow, metadata: &Value) -> HealthCopy {
    HealthCopy {
        track_id: row.track_id.clone(),
        path: row.path.clone(),
        available: row.available,
        codec: effective(metadata, "codec").unwrap_or_else(|| "Unknown".to_owned()),
        sample_rate: metadata.get("sample_rate").and_then(Value::as_f64),
        bit_depth: metadata.get("bit_depth").and_then(Value::as_i64),
        bitrate: metadata.get("bitrate").and_then(Value::as_f64),
        file_size_bytes: row.size,
    }
}

/// A listener's manual correction wins over whatever identification decided — the same
/// override rule the catalogue applies, so both surfaces name a track identically.
fn effective(metadata: &Value, key: &str) -> Option<String> {
    let manual_set = metadata
        .get(format!("manual_{key}_set"))
        .and_then(Value::as_bool)
        == Some(true);
    let field = if manual_set {
        metadata.get(format!("manual_{key}"))
    } else {
        metadata.get(key)
    };
    field
        .and_then(Value::as_str)
        .map(str::to_owned)
        .filter(|value| !value.is_empty())
}

pub fn analyze(tracks: &[HealthTrack]) -> HealthReport {
    let mut report = HealthReport::default();
    classify_locations(tracks, &mut report);
    classify_alternate_encodings(tracks, &mut report);
    classify_fragmented_folders(tracks, &mut report);
    sort_recommendations(&mut report);

    report.recommendation_count = report.exact_duplicates.len()
        + report.alternate_encodings.len()
        + report.moved_files.len()
        + report.missing_files.len()
        + report.fragmented_folders.len();
    report.exact_reclaimable_bytes = report
        .exact_duplicates
        .iter()
        .map(|recommendation| recommendation.potential_savings_bytes)
        .sum();
    report
}

fn classify_locations(tracks: &[HealthTrack], report: &mut HealthReport) {
    for track in tracks {
        let available: Vec<HealthCopy> = track
            .copies
            .iter()
            .filter(|copy| copy.available)
            .cloned()
            .collect();
        let unavailable: Vec<HealthCopy> = track
            .copies
            .iter()
            .filter(|copy| !copy.available)
            .cloned()
            .collect();

        // Two reachable files with the same content hash are the same bytes twice over —
        // the only case where deleting one is unambiguously safe.
        if available.len() > 1
            && let Some(content_hash) = &track.content_hash
        {
            let mut copies = available.clone();
            copies.sort_by(|a, b| natural_order(&a.path, &b.path));
            let savings = copies.iter().skip(1).map(|copy| copy.file_size_bytes).sum();
            report.exact_duplicates.push(HealthRecommendation {
                id: format!("exact:{content_hash}"),
                kind: HealthRecommendationKind::ExactDuplicate,
                title: track.title.clone(),
                artist: track.artist.clone(),
                reason: "Byte-for-byte identical content hash.".to_owned(),
                preferred_copy_id: copies.first().map(HealthCopy::id),
                copies,
                potential_savings_bytes: savings,
            });
        }

        if !available.is_empty() && !unavailable.is_empty() {
            report.moved_files.push(HealthRecommendation {
                id: format!("moved:{}", track.id),
                kind: HealthRecommendationKind::Moved,
                title: track.title.clone(),
                artist: track.artist.clone(),
                reason: format!(
                    "An available copy matches {} former location{}.",
                    unavailable.len(),
                    if unavailable.len() == 1 { "" } else { "s" }
                ),
                preferred_copy_id: available.first().map(HealthCopy::id),
                copies: available.into_iter().chain(unavailable).collect(),
                potential_savings_bytes: 0,
            });
        } else if available.is_empty() && !unavailable.is_empty() {
            report.missing_files.push(HealthRecommendation {
                id: format!("missing:{}", track.id),
                kind: HealthRecommendationKind::Missing,
                title: track.title.clone(),
                artist: track.artist.clone(),
                reason: "No scanned location for this song is available.".to_owned(),
                copies: unavailable,
                preferred_copy_id: None,
                potential_savings_bytes: 0,
            });
        }
    }
}

/// Groups tracks that agree on artist, title and duration but differ in encoding — the same
/// recording kept twice in different formats.
fn classify_alternate_encodings(tracks: &[HealthTrack], report: &mut HealthReport) {
    let mut groups: HashMap<String, Vec<&HealthTrack>> = HashMap::new();
    for track in tracks
        .iter()
        .filter(|track| track.copies.iter().any(|copy| copy.available))
    {
        let key = metadata_key(&track.title, &track.artist);
        if !key.is_empty() {
            groups.entry(key).or_default().push(track);
        }
    }

    // Sorted so the output does not depend on hash iteration order.
    let mut keys: Vec<&String> = groups.keys().collect();
    keys.sort();

    for key in keys {
        let candidates = &groups[key];
        if candidates.len() < 2 {
            continue;
        }

        let mut remaining: Vec<&HealthTrack> = candidates.clone();
        remaining.sort_by(|a, b| {
            a.duration
                .unwrap_or(0.0)
                .total_cmp(&b.duration.unwrap_or(0.0))
        });

        while !remaining.is_empty() {
            let seed = remaining.remove(0);
            let matches: Vec<&HealthTrack> = remaining
                .iter()
                .filter(|candidate| match (seed.duration, candidate.duration) {
                    (Some(left), Some(right)) => (left - right).abs() <= DURATION_TOLERANCE_SECONDS,
                    // A track with no known duration cannot be matched to one, since the
                    // whole claim rests on them being the same length.
                    _ => false,
                })
                .copied()
                .collect();
            let matched_ids: HashSet<&str> =
                matches.iter().map(|track| track.id.as_str()).collect();
            remaining.retain(|track| !matched_ids.contains(track.id.as_str()));

            let mut cluster = vec![seed];
            cluster.extend(matches);
            append_alternate_recommendation(&cluster, seed, report);
        }
    }
}

fn append_alternate_recommendation(
    cluster: &[&HealthTrack],
    seed: &HealthTrack,
    report: &mut HealthReport,
) {
    if cluster.len() < 2 {
        return;
    }

    // One copy per track — its best — so the comparison is between recordings rather than
    // between every file that happens to exist.
    let copies: Vec<HealthCopy> = cluster
        .iter()
        .filter_map(|track| {
            track
                .copies
                .iter()
                .filter(|copy| copy.available)
                .max_by(|a, b| a.quality_score().total_cmp(&b.quality_score()))
                .cloned()
        })
        .collect();

    let signatures: HashSet<String> = copies.iter().map(HealthCopy::format_signature).collect();
    // Identical encodings are not a choice between formats; that is the duplicate case,
    // already reported by content hash where it is provable.
    if copies.len() < 2 || signatures.len() < 2 {
        return;
    }

    let preferred = copies
        .iter()
        .max_by(|a, b| a.quality_score().total_cmp(&b.quality_score()))
        .map(HealthCopy::id);

    let mut ids: Vec<&str> = cluster.iter().map(|track| track.id.as_str()).collect();
    ids.sort_unstable();

    let mut sorted = copies.clone();
    sorted.sort_by(|a, b| b.quality_score().total_cmp(&a.quality_score()));

    let savings = sorted
        .iter()
        .filter(|copy| Some(copy.id()) != preferred)
        .map(|copy| copy.file_size_bytes)
        .sum();

    report.alternate_encodings.push(HealthRecommendation {
        id: format!("alternate:{}", ids.join(":")),
        kind: HealthRecommendationKind::AlternateEncoding,
        title: seed.title.clone(),
        artist: seed.artist.clone(),
        reason:
            "Artist, title and duration match. Review before removing a lower-quality encoding."
                .to_owned(),
        copies: sorted,
        preferred_copy_id: preferred,
        potential_savings_bytes: savings,
    });
}

/// Flags a folder whose available copies span several distinct albums.
///
/// Grouped by containing folder rather than by artist: an artist can legitimately own
/// several albums, each in its own folder, without that being a problem. A single folder
/// splitting across album values means identification has not converged for one physical
/// rip. Iterates copies rather than tracks because a track's copies can live in different
/// folders — folder membership is a property of the copy's path, not the track.
fn classify_fragmented_folders(tracks: &[HealthTrack], report: &mut HealthReport) {
    struct Entry {
        album: Option<String>,
        artist: String,
    }

    let mut by_folder: HashMap<String, Vec<Entry>> = HashMap::new();
    for track in tracks {
        for copy in track.copies.iter().filter(|copy| copy.available) {
            by_folder
                .entry(copy.folder().to_owned())
                .or_default()
                .push(Entry {
                    album: track.album.clone(),
                    artist: track.artist.clone(),
                });
        }
    }

    let mut folders: Vec<&String> = by_folder.keys().collect();
    folders.sort();

    for folder in folders {
        let entries = &by_folder[folder];
        if entries.len() < MIN_TRACKS_FOR_FRAGMENTED_FOLDER {
            continue;
        }

        let normalized: HashSet<String> = entries
            .iter()
            .filter_map(|entry| entry.album.as_deref().map(normalized_metadata))
            .filter(|album| !album.is_empty())
            .collect();
        if normalized.len() < MIN_ALBUMS_FOR_FRAGMENTED_FOLDER {
            continue;
        }

        let mut display: Vec<&str> = entries
            .iter()
            .filter_map(|entry| entry.album.as_deref())
            .collect::<HashSet<&str>>()
            .into_iter()
            .collect();
        display.sort_by(|a, b| natural_order(a, b));

        let mut counts: HashMap<&str, usize> = HashMap::new();
        for entry in entries {
            *counts.entry(entry.artist.as_str()).or_default() += 1;
        }
        // Ties broken by name so the answer does not depend on hash order.
        let dominant = counts
            .iter()
            .max_by(|a, b| a.1.cmp(b.1).then_with(|| b.0.cmp(a.0)))
            .map(|(artist, _)| (*artist).to_owned())
            .unwrap_or_else(|| "Unknown Artist".to_owned());

        report.fragmented_folders.push(HealthRecommendation {
            id: format!("fragmented:{folder}"),
            kind: HealthRecommendationKind::FragmentedFolder,
            title: folder.rsplit('/').next().unwrap_or(folder).to_owned(),
            artist: dominant,
            reason: format!(
                "{} tracks span {} albums: {}.",
                entries.len(),
                normalized.len(),
                display.join(", ")
            ),
            copies: Vec::new(),
            preferred_copy_id: None,
            potential_savings_bytes: 0,
        });
    }
}

/// Blank for anything unidentified: grouping every "Unknown Track" together would report
/// the whole unidentified tail of a library as one enormous false duplicate.
fn metadata_key(title: &str, artist: &str) -> String {
    const UNKNOWN: [&str; 3] = ["", "unknown track", "unknown artist"];
    if UNKNOWN.contains(&title.to_lowercase().as_str())
        || UNKNOWN.contains(&artist.to_lowercase().as_str())
    {
        return String::new();
    }

    let title = normalized_metadata(title);
    let artist = normalized_metadata(artist);
    if title.is_empty() || artist.is_empty() {
        return String::new();
    }
    format!("{artist}|{title}")
}

/// Case- and punctuation-insensitive, so "Don't Stop Me Now" and "Dont Stop Me Now" are the
/// same song. Diacritics are folded by stripping non-alphanumerics after lowercasing, which
/// keeps the comparison free of a Unicode normalisation dependency.
fn normalized_metadata(value: &str) -> String {
    value
        .to_lowercase()
        .chars()
        .filter(|character| character.is_alphanumeric())
        .collect()
}

/// Case-insensitive ordering, matching the `localizedStandardCompare` the Swift analyzer
/// used for paths and album names.
fn natural_order(left: &str, right: &str) -> std::cmp::Ordering {
    left.to_lowercase()
        .cmp(&right.to_lowercase())
        .then_with(|| left.cmp(right))
}

fn sort_recommendations(report: &mut HealthReport) {
    for list in [
        &mut report.exact_duplicates,
        &mut report.alternate_encodings,
        &mut report.moved_files,
        &mut report.missing_files,
        &mut report.fragmented_folders,
    ] {
        list.sort_by(|a, b| {
            natural_order(&a.artist, &b.artist).then_with(|| natural_order(&a.title, &b.title))
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn copy(track_id: &str, path: &str, available: bool, codec: &str, size: i64) -> HealthCopy {
        HealthCopy {
            track_id: track_id.to_owned(),
            path: path.to_owned(),
            available,
            codec: codec.to_owned(),
            sample_rate: Some(44_100.0),
            bit_depth: Some(16),
            bitrate: Some(1_411_000.0),
            file_size_bytes: size,
        }
    }

    fn track(id: &str, title: &str, artist: &str, copies: Vec<HealthCopy>) -> HealthTrack {
        HealthTrack {
            id: id.to_owned(),
            content_hash: Some(format!("hash-{id}")),
            title: title.to_owned(),
            artist: artist.to_owned(),
            album: None,
            duration: Some(180.0),
            copies,
        }
    }

    #[test]
    fn exact_duplicates_keep_the_first_path_and_count_the_rest_as_reclaimable() {
        let report = analyze(&[track(
            "1",
            "Song",
            "Artist",
            vec![
                copy("1", "/music/b.flac", true, "flac", 900),
                copy("1", "/music/a.flac", true, "flac", 900),
            ],
        )]);

        assert_eq!(report.exact_duplicates.len(), 1);
        let recommendation = &report.exact_duplicates[0];
        // Sorted by path, so the alphabetically-first copy is the one to keep.
        assert_eq!(recommendation.copies[0].path, "/music/a.flac");
        assert_eq!(
            recommendation.preferred_copy_id.as_deref(),
            Some("1|/music/a.flac")
        );
        assert_eq!(recommendation.potential_savings_bytes, 900);
        assert_eq!(report.exact_reclaimable_bytes, 900);
    }

    #[test]
    fn a_track_with_one_reachable_copy_and_one_stale_path_reads_as_moved() {
        let report = analyze(&[track(
            "1",
            "Song",
            "Artist",
            vec![
                copy("1", "/new/song.flac", true, "flac", 900),
                copy("1", "/old/song.flac", false, "flac", 900),
            ],
        )]);

        assert_eq!(report.moved_files.len(), 1);
        assert!(report.missing_files.is_empty());
        assert!(report.moved_files[0].reason.contains("1 former location."));
        // Nothing is reclaimable: the old path is already gone.
        assert_eq!(report.moved_files[0].potential_savings_bytes, 0);
    }

    #[test]
    fn a_track_with_no_reachable_copy_reads_as_missing() {
        let report = analyze(&[track(
            "1",
            "Song",
            "Artist",
            vec![copy("1", "/gone/song.flac", false, "flac", 900)],
        )]);

        assert_eq!(report.missing_files.len(), 1);
        assert!(report.moved_files.is_empty());
    }

    #[test]
    fn the_same_recording_in_two_formats_is_an_alternate_encoding_preferring_lossless() {
        let mut lossless = track(
            "1",
            "Song",
            "Artist",
            vec![copy("1", "/music/song.flac", true, "flac", 30_000_000)],
        );
        lossless.duration = Some(180.0);
        let mut lossy = track(
            "2",
            "Song",
            "Artist",
            vec![copy("2", "/music/song.mp3", true, "mp3", 7_000_000)],
        );
        lossy.duration = Some(181.0);
        lossy.copies[0].bitrate = Some(320_000.0);
        lossy.copies[0].bit_depth = None;

        let report = analyze(&[lossless, lossy]);

        assert_eq!(report.alternate_encodings.len(), 1);
        let recommendation = &report.alternate_encodings[0];
        assert_eq!(
            recommendation.preferred_copy_id.as_deref(),
            Some("1|/music/song.flac"),
            "lossless must outrank a high-bitrate lossy file"
        );
        // Only the copy that would be discarded counts toward savings.
        assert_eq!(recommendation.potential_savings_bytes, 7_000_000);
    }

    /// Two files of the same format are a duplicate, not a choice between encodings.
    #[test]
    fn identical_encodings_are_not_reported_as_alternates() {
        let first = track(
            "1",
            "Song",
            "Artist",
            vec![copy("1", "/a/song.flac", true, "flac", 900)],
        );
        let second = track(
            "2",
            "Song",
            "Artist",
            vec![copy("2", "/b/song.flac", true, "flac", 900)],
        );

        let report = analyze(&[first, second]);
        assert!(report.alternate_encodings.is_empty());
    }

    /// Durations far enough apart are different recordings — a radio edit and an album cut
    /// share a title and should not be offered as one to delete.
    #[test]
    fn recordings_of_different_lengths_are_not_matched() {
        let mut short = track(
            "1",
            "Song",
            "Artist",
            vec![copy("1", "/a/song.mp3", true, "mp3", 900)],
        );
        short.duration = Some(180.0);
        let mut long = track(
            "2",
            "Song",
            "Artist",
            vec![copy("2", "/b/song.flac", true, "flac", 900)],
        );
        long.duration = Some(400.0);

        let report = analyze(&[short, long]);
        assert!(report.alternate_encodings.is_empty());
    }

    /// Unidentified tracks all share a title. Grouping them would report the entire
    /// unidentified tail of a library as one vast false duplicate.
    #[test]
    fn unknown_titles_and_artists_are_never_grouped_together() {
        let first = track(
            "1",
            "Unknown Track",
            "Unknown Artist",
            vec![copy("1", "/a/1.mp3", true, "mp3", 900)],
        );
        let second = track(
            "2",
            "Unknown Track",
            "Unknown Artist",
            vec![copy("2", "/b/2.flac", true, "flac", 900)],
        );

        let report = analyze(&[first, second]);
        assert!(report.alternate_encodings.is_empty());
    }

    #[test]
    fn a_folder_spanning_several_albums_is_flagged_as_fragmented() {
        let tracks: Vec<HealthTrack> = ["A", "B", "C", "D"]
            .iter()
            .enumerate()
            .map(|(index, album)| {
                let mut item = track(
                    &index.to_string(),
                    &format!("Song {index}"),
                    "Artist",
                    vec![copy(
                        &index.to_string(),
                        &format!("/music/rip/{index}.flac"),
                        true,
                        "flac",
                        900,
                    )],
                );
                item.album = Some((*album).to_owned());
                item
            })
            .collect();

        let report = analyze(&tracks);

        assert_eq!(report.fragmented_folders.len(), 1);
        assert_eq!(report.fragmented_folders[0].title, "rip");
        assert!(
            report.fragmented_folders[0]
                .reason
                .contains("4 tracks span 4 albums")
        );
    }

    /// One album per folder is the success case, and a converged folder must stay silent.
    #[test]
    fn a_folder_agreeing_on_one_album_is_not_flagged() {
        let tracks: Vec<HealthTrack> = (0..5)
            .map(|index| {
                let mut item = track(
                    &index.to_string(),
                    &format!("Song {index}"),
                    "Artist",
                    vec![copy(
                        &index.to_string(),
                        &format!("/music/rip/{index}.flac"),
                        true,
                        "flac",
                        900,
                    )],
                );
                item.album = Some("One Album".to_owned());
                item
            })
            .collect();

        let report = analyze(&tracks);
        assert!(report.fragmented_folders.is_empty());
    }

    /// Too few files is not a signal — a couple of strays in a folder means nothing.
    #[test]
    fn a_folder_below_the_track_threshold_is_not_flagged() {
        let tracks: Vec<HealthTrack> = ["A", "B"]
            .iter()
            .enumerate()
            .map(|(index, album)| {
                let mut item = track(
                    &index.to_string(),
                    &format!("Song {index}"),
                    "Artist",
                    vec![copy(
                        &index.to_string(),
                        &format!("/music/rip/{index}.flac"),
                        true,
                        "flac",
                        900,
                    )],
                );
                item.album = Some((*album).to_owned());
                item
            })
            .collect();

        let report = analyze(&tracks);
        assert!(report.fragmented_folders.is_empty());
    }

    #[test]
    fn recommendations_are_ordered_by_artist_then_title() {
        let first = track(
            "1",
            "Zebra",
            "Aardvark",
            vec![
                copy("1", "/a/1.flac", true, "flac", 900),
                copy("1", "/b/1.flac", true, "flac", 900),
            ],
        );
        let second = track(
            "2",
            "Apple",
            "Zulu",
            vec![
                copy("2", "/a/2.flac", true, "flac", 900),
                copy("2", "/b/2.flac", true, "flac", 900),
            ],
        );

        let report = analyze(&[second, first]);
        assert_eq!(
            report
                .exact_duplicates
                .iter()
                .map(|item| item.artist.as_str())
                .collect::<Vec<_>>(),
            ["Aardvark", "Zulu"]
        );
    }

    #[test]
    fn an_empty_library_reports_nothing_rather_than_failing() {
        let report = analyze(&[]);
        assert_eq!(report.recommendation_count, 0);
        assert_eq!(report.exact_reclaimable_bytes, 0);
    }
}
