//! Thin client for `https://api.acoustid.org/v2/lookup`.
//!
//! AcoustID's published terms cap free/non-commercial use at ~3 requests/second and
//! ask that applications expecting significant traffic give advance notice — see
//! <https://acoustid.org/webservice>. The rate limiter here enforces the request
//! spacing side of that; the non-commercial-use and advance-notice conditions are a
//! usage-policy matter for whoever operates this service, not something code can
//! enforce.

use crate::rate_limit::RateLimiter;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use thiserror::Error;

const LOOKUP_URL: &str = "https://api.acoustid.org/v2/lookup";
const MAX_REQUESTS_PER_SECOND: f64 = 3.0;

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Http(#[from] reqwest::Error),
    #[error("AcoustID returned an error status: {0}")]
    Status(String),
}

pub struct AcoustIdClient {
    http: reqwest::Client,
    api_key: String,
    limiter: RateLimiter,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LookupResponse {
    pub status: String,
    #[serde(default)]
    pub results: Vec<LookupResult>,
    #[serde(default)]
    pub error: Option<LookupError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LookupError {
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LookupResult {
    pub id: String,
    #[serde(default)]
    pub score: f64,
    #[serde(default)]
    pub recordings: Vec<Recording>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recording {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub artists: Vec<Artist>,
    #[serde(default)]
    pub releasegroups: Vec<ReleaseGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artist {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseGroup {
    #[serde(default)]
    pub title: Option<String>,
}

impl AcoustIdClient {
    pub fn new(api_key: String) -> Self {
        Self {
            http: reqwest::Client::new(),
            api_key,
            limiter: RateLimiter::per_second(MAX_REQUESTS_PER_SECOND),
        }
    }

    pub async fn lookup(
        &self,
        fingerprint: &str,
        duration_secs: u32,
    ) -> Result<LookupResponse, Error> {
        self.limiter.acquire().await;
        // POST, not GET: a real compressed+base64 fingerprint for a full-length song
        // easily runs several KB, and a GET request that large hits the ~8KB URI
        // length limit many intermediate proxies enforce (observed directly: AcoustID
        // itself returns "invalid fingerprint" for the wrong algorithm, but a
        // fronting proxy returns a bare 414 "URI Too Long" for a correctly-sized one).
        // A POST body has no such ceiling.
        let response = self
            .http
            .post(LOOKUP_URL)
            .form(&[
                ("client", self.api_key.as_str()),
                ("duration", &duration_secs.to_string()),
                ("fingerprint", fingerprint),
                // Space-separated, not `+`-joined: AcoustID's docs show `+` because
                // that's how a browser address bar displays an encoded space in a GET
                // query string, not a literal character the API expects. A proper
                // url-encoder (reqwest's `.form()` included) percent-encodes a literal
                // `+` in a string as `%2B`, which decodes back to a literal `+` on
                // AcoustID's end — so `recordings+releasegroups+compress` arrives as
                // one unrecognized token and every `meta` flag gets silently ignored.
                // Confirmed directly: identical requests differing only in this
                // separator get back bare `{id, score}` results (space) vs a full
                // `recordings`/`releasegroups` payload (plus) for the same match.
                ("meta", "recordings releasegroups compress"),
            ])
            .send()
            .await?
            .error_for_status()?;
        let parsed: LookupResponse = response.json().await?;
        if parsed.status != "ok" {
            let message = parsed
                .error
                .as_ref()
                .map(|error| error.message.clone())
                .unwrap_or_else(|| parsed.status.clone());
            return Err(Error::Status(message));
        }
        Ok(parsed)
    }
}

/// AcoustID scores are 0.0-1.0 confidence, not a probability of correctness — low
/// scores are common for short/noisy/partial fingerprints and unreliable to act on.
/// Real AcoustID clients (fpcalc, MusicBrainz Picard) treat anything below ~0.5 as
/// "no reliable match" rather than accepting whatever scored highest.
const MIN_CONFIDENT_SCORE: f64 = 0.5;

/// Disambiguation hint for picking among several candidate recordings on the same
/// AcoustID result — see [`best_match`]. Typically the file's own existing tag data.
#[derive(Debug, Clone, Copy, Default)]
pub struct RecordingHint<'a> {
    pub title: Option<&'a str>,
    pub artist: Option<&'a str>,
}

/// Picks the highest-scoring result that clears [`MIN_CONFIDENT_SCORE`], and within
/// it the recording `hint`/`known_release_titles` point at. Returns `None` if
/// nothing meets the confidence bar, which callers treat the same as "no match" —
/// safe to retry later rather than persisting a wrong guess.
///
/// The hint matters even at high confidence: a single AcoustID fingerprint cluster
/// can have several *different* MusicBrainz recordings linked to it — AcoustID's
/// database is crowd-sourced, and mislinking happens. Observed directly: a fully
/// correct, 97%-confidence fingerprint match for Arctic Monkeys' "R U Mine?" carried
/// `recordings: [Metro Station – "Control", Arctic Monkeys – "Snap Out of It",
/// Arctic Monkeys – "R U Mine?", ...]` on the *same* result — picking
/// `recordings.first()` returned the wrong song outright, and matching on artist
/// alone still wasn't enough to land on the right *song* (it landed on a different
/// Arctic Monkeys track first). Title is what actually pins the right recording down.
///
/// `known_release_titles` is `aro-track-id::matching`-normalized artist name →
/// the release titles that artist's other tracks have already converged on (see
/// `aro_sync_store::HubStore::release_title_affinity`). It resolves a case title
/// alone can't: the *same song title* is frequently attached to two genuinely
/// different MusicBrainz recordings — the original single/standalone master, and
/// a distinct re-recording or edit that's actually the one included on the album
/// (observed directly: Neck Deep's "December" carries both a recording linked only
/// to the "December" single, *and* a separate recording linked to "Life's Not Out
/// to Get You" — both title- and artist-match the file's tags identically, so only
/// knowing which album this artist's other tracks are on can tell them apart).
pub fn best_match<'a>(
    response: &'a LookupResponse,
    hint: RecordingHint<'_>,
    known_release_titles: &HashMap<String, HashSet<String>>,
) -> Option<(&'a LookupResult, Option<&'a Recording>)> {
    response
        .results
        .iter()
        .filter(|result| result.score >= MIN_CONFIDENT_SCORE)
        .max_by(|a, b| a.score.total_cmp(&b.score))
        .map(|result| (result, best_recording(result, hint, known_release_titles)))
}

fn normalize(value: &str) -> String {
    crate::matching::normalize_matching_key(value)
}

fn best_recording<'a>(
    result: &'a LookupResult,
    hint: RecordingHint<'_>,
    known_release_titles: &HashMap<String, HashSet<String>>,
) -> Option<&'a Recording> {
    let hint_title = hint.title.map(normalize).filter(|value| !value.is_empty());
    let hint_artist = hint.artist.map(normalize).filter(|value| !value.is_empty());

    let matches_title = |recording: &Recording| {
        hint_title.as_deref().is_some_and(|hint| {
            recording
                .title
                .as_deref()
                .is_some_and(|title| normalize(title) == hint)
        })
    };
    let matches_artist = |recording: &Recording| {
        hint_artist.as_deref().is_some_and(|hint| {
            recording.artists.iter().any(|artist| {
                artist
                    .name
                    .as_deref()
                    .is_some_and(|name| normalize(name) == hint)
            })
        })
    };
    let matches_known_album = |recording: &Recording| {
        recording.artists.iter().any(|artist| {
            artist.name.as_deref().is_some_and(|name| {
                known_release_titles
                    .get(&normalize(name))
                    .is_some_and(|titles| {
                        recording.releasegroups.iter().any(|group| {
                            group
                                .title
                                .as_deref()
                                .is_some_and(|title| titles.contains(&normalize(title)))
                        })
                    })
            })
        })
    };

    // Title + artist + a release this artist is already known for, first — this
    // is the only tier that can tell apart two recordings that are otherwise
    // identical by title and artist (see the doc comment above). Then title +
    // artist together alone (pins down the exact recording in the common case),
    // then title alone, then artist alone (narrows the field but, as observed,
    // not always to a single recording), and only then whatever AcoustID listed
    // first.
    result
        .recordings
        .iter()
        .find(|recording| {
            matches_title(recording) && matches_artist(recording) && matches_known_album(recording)
        })
        .or_else(|| {
            result
                .recordings
                .iter()
                .find(|recording| matches_title(recording) && matches_artist(recording))
        })
        .or_else(|| {
            result
                .recordings
                .iter()
                .find(|recording| matches_title(recording))
        })
        .or_else(|| {
            result
                .recordings
                .iter()
                .find(|recording| matches_artist(recording))
        })
        .or_else(|| result.recordings.first())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recording(id: &str, title: &str, artists: &[&str], releasegroups: &[&str]) -> Recording {
        Recording {
            id: id.to_string(),
            title: Some(title.to_string()),
            artists: artists
                .iter()
                .map(|name| Artist {
                    name: Some(name.to_string()),
                })
                .collect(),
            releasegroups: releasegroups
                .iter()
                .map(|title| ReleaseGroup {
                    title: Some(title.to_string()),
                })
                .collect(),
        }
    }

    fn result(id: &str, score: f64, recordings: Vec<Recording>) -> LookupResult {
        LookupResult {
            id: id.to_string(),
            score,
            recordings,
        }
    }

    /// The real case that motivated this tier: Neck Deep's "December" is two
    /// distinct MusicBrainz recordings — one linked only to the "December"
    /// single, one also linked to "Life's Not Out to Get You" — with
    /// identical title and (mostly) identical artist credit, so title+artist
    /// hint matching alone can't tell them apart. Once the artist has
    /// established affinity for the album, the ambiguous track must resolve
    /// to the recording linked to it.
    #[test]
    fn known_album_disambiguates_two_identically_titled_recordings() {
        let response = LookupResponse {
            status: "ok".into(),
            error: None,
            results: vec![result(
                "df6e7870",
                0.999,
                vec![
                    recording(
                        "single-only",
                        "December",
                        &["Neck Deep", "Chris Carrabba"],
                        &["December"],
                    ),
                    recording(
                        "album-track",
                        "December",
                        &["Neck Deep"],
                        &["Life's Not Out to Get You", "December"],
                    ),
                ],
            )],
        };
        let hint = RecordingHint {
            title: Some("December"),
            artist: Some("Neck Deep"),
        };
        let mut known = HashMap::new();
        known.insert(
            "neck deep".to_string(),
            HashSet::from(["life's not out to get you".to_string()]),
        );

        let (_, recording) = best_match(&response, hint, &known).unwrap();

        assert_eq!(recording.unwrap().id, "album-track");
    }

    /// With no affinity established yet, behavior is unchanged from before
    /// this tier existed: title+artist match picks whichever AcoustID listed
    /// first among tied candidates.
    #[test]
    fn falls_back_to_first_title_artist_match_with_no_affinity() {
        let response = LookupResponse {
            status: "ok".into(),
            error: None,
            results: vec![result(
                "df6e7870",
                0.999,
                vec![
                    recording("single-only", "December", &["Neck Deep"], &["December"]),
                    recording(
                        "album-track",
                        "December",
                        &["Neck Deep"],
                        &["Life's Not Out to Get You"],
                    ),
                ],
            )],
        };
        let hint = RecordingHint {
            title: Some("December"),
            artist: Some("Neck Deep"),
        };

        let (_, recording) = best_match(&response, hint, &HashMap::new()).unwrap();

        assert_eq!(recording.unwrap().id, "single-only");
    }

    /// Affinity lookups must be keyed consistently regardless of which
    /// dash/hyphen glyph an artist's name happens to use in a given payload —
    /// observed directly for blink-182 (see `matching::normalize_matching_key`).
    #[test]
    fn known_album_matches_across_unicode_hyphen_variants() {
        let response = LookupResponse {
            status: "ok".into(),
            error: None,
            results: vec![result(
                "abc123",
                0.99,
                vec![
                    recording(
                        "wrong",
                        "Feeling This",
                        &["blink\u{2010}182"],
                        &["Live Sarnya Bayfest"],
                    ),
                    recording(
                        "right",
                        "Feeling This",
                        &["blink\u{2010}182"],
                        &["Greatest Hits"],
                    ),
                ],
            )],
        };
        let hint = RecordingHint {
            title: Some("Feeling This"),
            artist: Some("blink-182"),
        };
        let mut known = HashMap::new();
        known.insert(
            "blink-182".to_string(),
            HashSet::from(["greatest hits".to_string()]),
        );

        let (_, recording) = best_match(&response, hint, &known).unwrap();

        assert_eq!(recording.unwrap().id, "right");
    }

    /// Unrelated recordings sharing a fingerprint cluster (the Arctic
    /// Monkeys/Metro Station case) must still be told apart by title even
    /// when neither has any affinity — this tier must never override a case
    /// title alone already resolves correctly.
    #[test]
    fn title_alone_still_wins_when_titles_differ() {
        let response = LookupResponse {
            status: "ok".into(),
            error: None,
            results: vec![result(
                "r-u-mine",
                0.97,
                vec![
                    recording("metro-station", "Control", &["Metro Station"], &[]),
                    recording("snap-out-of-it", "Snap Out of It", &["Arctic Monkeys"], &[]),
                    recording("r-u-mine", "R U Mine?", &["Arctic Monkeys"], &["AM"]),
                ],
            )],
        };
        let hint = RecordingHint {
            title: Some("R U Mine?"),
            artist: Some("Arctic Monkeys"),
        };

        let (_, recording) = best_match(&response, hint, &HashMap::new()).unwrap();

        assert_eq!(recording.unwrap().id, "r-u-mine");
    }
}
