//! End-to-end characterization tests against real, recorded AcoustID/MusicBrainz data (see
//! `fixtures`). These pin *today's* decision-logic behaviour before any of the
//! tracklist-matching work in this session touches it, so later phases can prove
//! non-regression by re-running these unchanged rather than asserting it by inspection.
//!
//! Two of these ((`december_neck_deep_...`) also document a genuine bug present in the live
//! `mercury` library at the time this session started: track 9 of "Life's Not Out to Get
//! You" is a `blink‐182`-style already-affinity-solvable case, but the live per-file result
//! was written *before* the artist's affinity converged and was never revisited (no
//! mechanism re-runs an already-identified file) -- exactly the cold-start/no-reconcile gap
//! a later phase addresses. The pure decision function (`best_recording`) already resolves
//! it correctly *given* the affinity that exists today, which this test proves directly.

use crate::{acoustid, fixtures};
use std::collections::{HashMap, HashSet};

#[test]
fn every_fixture_deserializes() {
    for name in ["december-neck-deep", "beatles-1-track-09", "blink-182-hyphen-dammit"] {
        fixtures::acoustid_lookup(name);
        fixtures::mb_recording(name);
    }
    for name in [
        "beatles-1",
        "blink-182-greatest-hits",
        "arctic-monkeys-am",
        "neck-deep-lifes-not-out-to-get-you",
    ] {
        fixtures::mb_release_raw(name);
    }
    for name in [
        "beatles-1",
        "blink-182-greatest-hits",
        "arctic-monkeys-am",
        "neck-deep-lifes-not-out-to-get-you",
        "mixed-bag",
    ] {
        let group = fixtures::group(name);
        assert!(!group.files.is_empty(), "{name} fixture has no files");
    }
}

/// The load-bearing budget assumption for the tracklist-matching phases: MusicBrainz
/// release stubs already carry `media[].track-count` and a track-position/title/length stub
/// for free once `inc=media` is requested -- verified directly against the live API before
/// writing this fixture (absent without `+media`, present with it, no extra request). If
/// this ever fails against a re-captured fixture, candidate-release shortlisting loses its
/// zero-request signal and the fetch budget for a group pass needs revisiting.
#[test]
fn release_stub_media_carries_track_count_and_position() {
    let release = fixtures::mb_release_raw("beatles-1");
    let media = release["media"].as_array().expect("release should have media");
    assert!(!media.is_empty());
    let track_count = media[0]["track-count"].as_u64().expect("medium should have a track-count");
    assert_eq!(track_count, 27);
    let tracks = media[0]["tracks"].as_array().expect("medium should have tracks");
    assert_eq!(tracks.len(), 27);
    assert!(tracks[0]["position"].is_u64());
    assert!(tracks[0]["title"].is_string());
    assert!(tracks[0]["length"].is_u64());
}

/// A full `ws/2/release/{id}?inc=recordings+...` fetch (as opposed to the release *stub*
/// embedded in a recording lookup) carries a nested `recording` object, with its own id, per
/// track -- the field group-vs-tracklist matching (a later phase) actually needs, since it
/// has to know which specific recording a tracklist position corresponds to.
#[test]
fn full_release_tracks_carry_a_nested_recording_id() {
    let release = fixtures::mb_release("beatles-1");
    let track = &release.media[0].tracks[0];
    let recording = track.recording.as_ref().expect("track should carry a recording");
    assert!(!recording.id.is_empty());
    assert_eq!(track.title.as_deref(), Some("Love Me Do"));
}

/// By contrast, a recording lookup's *embedded* release stub (even with `+media`) has no
/// nested recording per track -- only a full release fetch does (see the test above). This
/// is the concrete reason a full `MusicBrainzClient::release` fetch is still needed for
/// group matching, and it can't be skipped by reusing the cheaper recording-lookup media
/// stub alone.
#[test]
fn recording_endpoint_media_stub_lacks_nested_recording_per_track() {
    let recording = fixtures::mb_recording_with_media("ticket-to-ride");
    let release = recording
        .releases
        .iter()
        .find(|release| !release.media.is_empty() && !release.media[0].tracks.is_empty())
        .expect("fixture should have at least one release with track stubs");
    let track = &release.media[0].tracks[0];
    assert!(track.recording.is_none());
    // The track-count/track-offset signal `album::shortlist_candidates` ranks on is still
    // present, even without the per-track recording id.
    assert!(release.media[0].track_count.is_some());
}

/// Cold state (no affinity yet): AcoustID's fingerprint cluster for this exact real file
/// carries over 20 distinct "Ticket to Ride" recordings by The Beatles alone, linked to
/// different release-groups ("Help!", "27 No. 1 Singles", "Songs for Eleanor", ...) -- a
/// real instance of the recording-ambiguity problem this whole session addresses. With no
/// affinity, tier 2 (title+artist) picks AcoustID's first such candidate in list order. This
/// is what the live system actually chose; pinned here so a refactor can't silently change
/// it, not as an endorsement that this candidate is the "right" one.
#[test]
fn beatles_1_track_09_falls_back_to_first_title_artist_match_with_no_affinity() {
    let lookup = fixtures::acoustid_lookup("beatles-1-track-09");
    let hint = acoustid::RecordingHint {
        title: Some("Ticket to Ride"),
        artist: Some("The Beatles"),
    };
    let (_, recording) = acoustid::best_match(&lookup, hint, &HashMap::new()).expect("should match");
    let recording = recording.expect("should resolve a recording");
    assert_eq!(recording.id, "00c47ea6-3a10-4a32-b1f1-990ac756c6a0");
}

/// The blink-182 hyphen-glyph case: this real fingerprint cluster carries two genuinely
/// distinct recordings both titled "Dammit" by an artist AcoustID itself spells with a
/// typographic U+2010 hyphen (`blink‐182`). Passing an ordinary ASCII-hyphen hint must still
/// match via `normalize_matching_key`'s dash-folding.
#[test]
fn blink_182_hyphen_variant_in_acoustid_data_still_matches_ascii_hint() {
    let lookup = fixtures::acoustid_lookup("blink-182-hyphen-dammit");
    let hint = acoustid::RecordingHint {
        title: Some("Dammit"),
        artist: Some("blink-182"), // ASCII hyphen; AcoustID's own data uses U+2010.
    };
    let (_, recording) = acoustid::best_match(&lookup, hint, &HashMap::new()).expect("should match");
    let recording = recording.expect("should resolve a recording");
    assert_eq!(recording.id, "7119c66f-5774-4c3f-b82a-2656b2406649");
}

/// The Neck Deep "December" case, with the artist's *real* affinity as captured from the
/// live store (24 tracks recorded against "Life's Not Out to Get You", 2 against the
/// "December" single). Given that affinity, tier 1 (title + artist + known album) must pick
/// the recording actually linked to the album, not the single -- even though both
/// recordings tie on title and artist alone. This is the exact real-world case the live
/// system's per-file result got stuck on (see module doc): the pure function already gets it
/// right when handed today's affinity; only the missing reconcile mechanism does not.
#[test]
fn december_neck_deep_known_album_affinity_resolves_to_the_album_recording() {
    let lookup = fixtures::acoustid_lookup("december-neck-deep");
    let hint = acoustid::RecordingHint {
        title: Some("December"),
        artist: Some("Neck Deep"),
    };
    let mut known_release_titles = HashMap::new();
    // U+2019 (curly apostrophe), not U+0027 -- this is the exact glyph both AcoustID's
    // releasegroup title and MusicBrainz's own release title use for "Life's". A plain
    // ASCII apostrophe here silently fails to match despite `normalize_matching_key`
    // (which only folds dash variants, not apostrophes) -- worth knowing since a future
    // affinity-title bug of this shape would be invisible without a fixture this exact.
    known_release_titles.insert(
        "neck deep".to_string(),
        HashSet::from(["life\u{2019}s not out to get you".to_string()]),
    );

    let (_, recording) =
        acoustid::best_match(&lookup, hint, &known_release_titles).expect("should match");
    let recording = recording.expect("should resolve a recording");
    assert_eq!(recording.id, "b2582384-7f2d-41ea-b08d-c2aa49566704");
}

/// Same fixture, no affinity: without knowing which album this artist's other tracks landed
/// on, tier 2 (title+artist) can't distinguish the two "December" recordings and falls back
/// to AcoustID's list order -- which happens to be the single, the exact bug this session's
/// grouping work fixes structurally (see `album` module). Pinned so the "no affinity" path
/// stays exactly as messy as it really is today.
#[test]
fn december_neck_deep_falls_back_to_first_match_with_no_affinity() {
    let lookup = fixtures::acoustid_lookup("december-neck-deep");
    let hint = acoustid::RecordingHint {
        title: Some("December"),
        artist: Some("Neck Deep"),
    };
    let (_, recording) = acoustid::best_match(&lookup, hint, &HashMap::new()).expect("should match");
    let recording = recording.expect("should resolve a recording");
    assert_eq!(recording.id, "33cab056-bba2-44da-bf42-600edd146587");
}
