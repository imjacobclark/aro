//! Recorded AcoustID/MusicBrainz payloads used by offline tests, so the decision logic in
//! this crate (`best_match`, `select_release`, and the group-matching in `album`) can be
//! validated in milliseconds against real data instead of a live Pi rebuild + network
//! rescan, which took 15-40 minutes per iteration during the session that produced these.
//!
//! Every fixture under `server/fixtures/track-id/` was captured from the real, live
//! `mercury` test library's hub database (`identification_cache`, `identification_results`,
//! `release_group_affinity`, `source_files`) and the public MusicBrainz API — nothing here
//! is synthesized, with the single exception of `groups/mixed-bag.json`, which is
//! deliberately assembled from fragments of two unrelated real albums to exercise
//! rejection.
//!
//! Loaded via `include_str!` behind a `match` on a name, so a missing fixture is a compile
//! error rather than a runtime path bug (`include_str!` needs a string literal, so this
//! can't be a generic `format!`-based path lookup).

// Several fields aren't read yet -- they exist for the group-matching phases that follow
// Phase 0 and for test-assertion readability (`content_hash`, `previously_chosen_recording_id`),
// not because they're unused by design.
#![allow(dead_code)]

use crate::{acoustid, musicbrainz};
use serde::Deserialize;

pub(crate) fn acoustid_lookup(name: &str) -> acoustid::LookupResponse {
    let json = match name {
        "december-neck-deep" => {
            include_str!("../../../fixtures/track-id/acoustid/december-neck-deep.json")
        }
        "beatles-1-track-09" => {
            include_str!("../../../fixtures/track-id/acoustid/beatles-1-track-09.json")
        }
        "blink-182-hyphen-dammit" => {
            include_str!("../../../fixtures/track-id/acoustid/blink-182-hyphen-dammit.json")
        }
        other => panic!("no acoustid fixture named {other:?}"),
    };
    serde_json::from_str(json).expect("fixture should deserialize")
}

pub(crate) fn mb_recording(name: &str) -> musicbrainz::RecordingResponse {
    let json = match name {
        "december-neck-deep" => {
            include_str!("../../../fixtures/track-id/musicbrainz/recording-december-neck-deep.json")
        }
        "beatles-1-track-09" => {
            include_str!("../../../fixtures/track-id/musicbrainz/recording-beatles-1-track-09.json")
        }
        "blink-182-hyphen-dammit" => {
            include_str!(
                "../../../fixtures/track-id/musicbrainz/recording-blink-182-hyphen-dammit.json"
            )
        }
        other => panic!("no musicbrainz recording fixture named {other:?}"),
    };
    serde_json::from_str(json).expect("fixture should deserialize")
}

/// The same fixtures as [`mb_release_raw`], but deserialized through the typed
/// `ReleaseResponse`. Kept as a separate function (rather than replacing `mb_release_raw`)
/// so the `release_stub_media_carries_track_count_and_position` characterization test can
/// keep checking the *raw* JSON shape independent of whatever this crate's types currently
/// parse — that test predates `ReleaseResponse` and is meant to survive any future
/// refactor of it unchanged.
pub(crate) fn mb_release(name: &str) -> musicbrainz::ReleaseResponse {
    let value = mb_release_raw(name);
    serde_json::from_value(value).expect("fixture should deserialize")
}

/// A real `ws/2/recording/{id}?inc=...+media` response — unlike the fixtures loaded by
/// [`mb_recording`], captured *with* `+media` in the request, so its release stubs carry
/// `media[].track-count` but (unlike a full [`mb_release`] fetch) no nested `recording` per
/// track — see `Track::recording`'s doc comment for why that distinction matters.
pub(crate) fn mb_recording_with_media(name: &str) -> musicbrainz::RecordingResponse {
    let json = match name {
        "ticket-to-ride" => {
            include_str!(
                "../../../fixtures/track-id/musicbrainz/recording-ticket-to-ride-with-media.json"
            )
        }
        other => panic!("no musicbrainz recording-with-media fixture named {other:?}"),
    };
    serde_json::from_str(json).expect("fixture should deserialize")
}

/// Raw JSON for a `ws/2/release/{id}?inc=recordings+artist-credits+release-groups` response.
pub(crate) fn mb_release_raw(name: &str) -> serde_json::Value {
    let json = match name {
        "beatles-1" => {
            include_str!("../../../fixtures/track-id/musicbrainz/release-beatles-1.json")
        }
        "blink-182-greatest-hits" => {
            include_str!(
                "../../../fixtures/track-id/musicbrainz/release-blink-182-greatest-hits.json"
            )
        }
        "arctic-monkeys-am" => {
            include_str!("../../../fixtures/track-id/musicbrainz/release-arctic-monkeys-am.json")
        }
        "neck-deep-lifes-not-out-to-get-you" => include_str!(
            "../../../fixtures/track-id/musicbrainz/release-neck-deep-lifes-not-out-to-get-you.json"
        ),
        other => panic!("no musicbrainz release fixture named {other:?}"),
    };
    serde_json::from_str(json).expect("fixture should deserialize")
}

/// One file's real, independently-sourced evidence within a [`GroupFixture`] folder:
/// `file_name`/`tag_title`/`tag_track_number` are parsed from the real scanned relative
/// path; `duration_secs` and `candidate_recording_ids` come from the real decoded audio and
/// the real cached AcoustID response. The `*_before` / `previously_chosen_recording_id`
/// fields are the *prior* per-file pipeline's already-computed answer for that file (kept
/// for comparison in test assertions) and must never be fed into group-matching as if they
/// were independent evidence -- see the `note` field embedded in each fixture file.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct GroupFileFixture {
    pub file_name: String,
    #[allow(dead_code)]
    pub content_hash: String,
    pub duration_secs: Option<u32>,
    pub tag_title: Option<String>,
    #[allow(dead_code)]
    pub tag_track_number: Option<u32>,
    pub candidate_recording_ids: Vec<String>,
    #[allow(dead_code)]
    pub resolved_artist_before: Option<String>,
    pub observed_album_before: Option<String>,
    #[allow(dead_code)]
    pub previously_chosen_recording_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct GroupFixture {
    #[allow(dead_code)]
    pub folder: String,
    pub files: Vec<GroupFileFixture>,
}

pub(crate) fn group(name: &str) -> GroupFixture {
    let json = match name {
        "beatles-1" => include_str!("../../../fixtures/track-id/groups/beatles-1.json"),
        "blink-182-greatest-hits" => {
            include_str!("../../../fixtures/track-id/groups/blink-182-greatest-hits.json")
        }
        "arctic-monkeys-am" => {
            include_str!("../../../fixtures/track-id/groups/arctic-monkeys-am.json")
        }
        "neck-deep-lifes-not-out-to-get-you" => {
            include_str!(
                "../../../fixtures/track-id/groups/neck-deep-lifes-not-out-to-get-you.json"
            )
        }
        "mixed-bag" => include_str!("../../../fixtures/track-id/groups/mixed-bag.json"),
        other => panic!("no group fixture named {other:?}"),
    };
    serde_json::from_str(json).expect("fixture should deserialize")
}
