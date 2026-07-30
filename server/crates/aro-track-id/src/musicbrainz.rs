//! Thin client for the public MusicBrainz webservice
//! (`https://musicbrainz.org/ws/2/`), used to enrich an AcoustID match with canonical
//! recording/artist/release data.
//!
//! MusicBrainz enforces ~1 request/second per source IP and actively throttles
//! applications with a missing or generic `User-Agent` — see
//! <https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting>. `user_agent` must be a
//! real, honest identifier with contact information; it is operator-supplied
//! configuration, not hardcoded here.

use crate::rate_limit::RateLimiter;
use serde::{Deserialize, Serialize};
use std::{cmp::Reverse, collections::HashMap};
use thiserror::Error;

const MAX_REQUESTS_PER_SECOND: f64 = 1.0;

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Http(#[from] reqwest::Error),
    #[error(transparent)]
    InvalidUserAgent(#[from] reqwest::header::InvalidHeaderValue),
}

pub struct MusicBrainzClient {
    http: reqwest::Client,
    user_agent: String,
    limiter: RateLimiter,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingResponse {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default, rename = "artist-credit")]
    pub artist_credit: Vec<ArtistCredit>,
    #[serde(default)]
    pub releases: Vec<Release>,
    /// MusicBrainz's own curated genre subset — present once `inc=genres` is requested.
    /// Unlike [`Self::tags`] (the broader, uncurated folksonomy), these are already genre
    /// names, not free-form community text, so [`canonicalize_tags`] passes them through
    /// directly rather than matching them against a keyword table.
    #[serde(default)]
    pub genres: Vec<MbTag>,
    /// The full folksonomy tag list — present once `inc=tags` is requested. Includes moods,
    /// scenes, and noise ("seen live", "favorites") alongside genre-ish terms; MusicBrainz
    /// has no dedicated mood vocabulary, so [`canonicalize_tags`] matches these against a
    /// small keyword table to derive mood instead.
    #[serde(default)]
    pub tags: Vec<MbTag>,
}

/// One community-contributed folksonomy tag or curated genre, as returned by MusicBrainz's
/// `inc=tags`/`inc=genres`. `count` is the number of users who applied it — used to rank
/// which tags are actually representative rather than one person's one-off label.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MbTag {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistCredit {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Release {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default, rename = "release-group")]
    pub release_group: Option<ReleaseGroup>,
    /// Track-count/tracklist stubs for this release, present for free once `inc=media` is
    /// requested — verified directly against the live API (absent without it, present with
    /// it, no extra request). This is what lets candidate-release shortlisting for a group
    /// of files (see `album::shortlist_candidates`) rank releases by track-count agreement
    /// using data already fetched for the ordinary per-file recording lookup, without a
    /// separate release fetch per candidate.
    #[serde(default)]
    pub media: Vec<Medium>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseGroup {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default, rename = "primary-type")]
    pub primary_type: Option<String>,
    #[serde(default, rename = "secondary-types")]
    pub secondary_types: Vec<String>,
    #[serde(default)]
    pub title: Option<String>,
}

/// One physical/logical medium (a CD, a vinyl side, a digital release) within a release,
/// carrying its own tracklist. `track_count` is a plain integer even when `tracks` itself
/// wasn't requested (e.g. a `recording?inc=...+media` stub, as opposed to a full
/// `release?inc=recordings+...` fetch) — that distinction is exactly what makes
/// candidate-release shortlisting free (see [`Release::media`]'s doc comment).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Medium {
    #[serde(default)]
    pub position: Option<u32>,
    #[serde(default, rename = "track-count")]
    pub track_count: Option<u32>,
    #[serde(default, rename = "track-offset")]
    pub track_offset: Option<u32>,
    #[serde(default)]
    pub format: Option<String>,
    #[serde(default)]
    pub tracks: Vec<Track>,
}

/// One track stub within a [`Medium`]'s tracklist, as returned by a full
/// `ws/2/release/{id}?inc=recordings+...` fetch (a `recording?inc=...+media` stub's media
/// entries carry `track_count`/`track_offset` only, with an empty `tracks`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Track {
    pub id: String,
    #[serde(default)]
    pub position: Option<u32>,
    /// Free-form catalogue track number ("A1", "9", ...) — deliberately not parsed as an
    /// integer, unlike `position`, since vinyl/cassette side labels aren't numeric.
    #[serde(default)]
    pub number: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// Milliseconds.
    #[serde(default)]
    pub length: Option<u64>,
    #[serde(default)]
    pub recording: Option<TrackRecording>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackRecording {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub length: Option<u64>,
    #[serde(default, rename = "artist-credit")]
    pub artist_credit: Vec<ArtistCredit>,
}

/// A full `ws/2/release/{id}?inc=recordings+artist-credits+release-groups` response —
/// unlike the release *stubs* embedded in a [`RecordingResponse`], this carries each
/// medium's complete ordered [`Track`] list (with per-track recording ids and lengths),
/// which is what a batch group-vs-tracklist match (see the `album` module) needs. Fetched
/// only for the handful of candidate releases a group of files has already shortlisted —
/// see [`MusicBrainzClient::release`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseResponse {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default, rename = "artist-credit")]
    pub artist_credit: Vec<ArtistCredit>,
    #[serde(default, rename = "release-group")]
    pub release_group: Option<ReleaseGroup>,
    #[serde(default)]
    pub media: Vec<Medium>,
}

/// Release-group affinity for one artist, collapsed into *title equivalence classes*
/// rather than kept purely per-MBID. Real MusicBrainz data routinely links the "same"
/// album (by title, to a listener) to several distinct release-group ids — different
/// pressings, markets, or catalogue entries — which otherwise splits what should be one
/// affinity signal into several weaker ones (observed directly: three different
/// release-group ids all titled "The Beatles" for one artist). Consolidating by
/// `matching::normalize_matching_key`-normalized title fixes that at the level the user
/// actually experiences: "album", not "MBID". A row with no title can't be matched against
/// anything else and stays its own singleton class.
///
/// Built from [`aro_sync_store::ReleaseGroupAffinityRow`]s via [`Self::from_rows`]; see
/// [`select_release`] for how it's consumed.
#[derive(Debug, Default)]
pub struct AffinityIndex {
    class_of_group: HashMap<String, String>,
    class_total: HashMap<String, i64>,
    canonical_of_class: HashMap<String, String>,
}

impl AffinityIndex {
    pub fn from_rows(rows: &[aro_sync_store::ReleaseGroupAffinityRow]) -> Self {
        Self::from_entries(rows.iter().map(|row| {
            (
                row.release_group_id.clone(),
                row.release_title.clone(),
                row.track_count,
            )
        }))
    }

    /// Test-only convenience: builds an index directly from `(release_group_id, count)`
    /// pairs with no title information, so each release-group id is its own class — i.e.
    /// affinity behaves exactly as it did before title-class consolidation existed. Lets
    /// `select_release`'s other ranking tiers be exercised without class-consolidation
    /// noise.
    #[cfg(test)]
    pub fn from_counts<I: IntoIterator<Item = (String, i64)>>(counts: I) -> Self {
        Self::from_entries(counts.into_iter().map(|(id, count)| (id, None, count)))
    }

    fn from_entries<I: IntoIterator<Item = (String, Option<String>, i64)>>(entries: I) -> Self {
        let mut class_of_group = HashMap::new();
        let mut class_total: HashMap<String, i64> = HashMap::new();
        // Tracks the best (highest count, then lexicographically smallest id) release-group
        // id seen so far per class, so the canonical member is chosen deterministically
        // regardless of row order — needed for byte-identical results across repeated
        // passes over the same data.
        let mut best_in_class: HashMap<String, (i64, String)> = HashMap::new();

        for (release_group_id, release_title, track_count) in entries {
            // NUL can't appear in a real MusicBrainz title, so this can never collide with
            // a genuine normalized title — it just gives every untitled row its own class.
            let class = match &release_title {
                Some(title) => normalize(title),
                None => format!("\0untitled:{release_group_id}"),
            };
            class_of_group.insert(release_group_id.clone(), class.clone());
            *class_total.entry(class.clone()).or_insert(0) += track_count;
            best_in_class
                .entry(class)
                .and_modify(|(best_count, best_id)| {
                    if track_count > *best_count
                        || (track_count == *best_count && release_group_id < *best_id)
                    {
                        *best_count = track_count;
                        *best_id = release_group_id.clone();
                    }
                })
                .or_insert((track_count, release_group_id));
        }

        let canonical_of_class = best_in_class
            .into_iter()
            .map(|(class, (_, id))| (class, id))
            .collect();

        Self {
            class_of_group,
            class_total,
            canonical_of_class,
        }
    }

    /// The total track count across every release-group id that shares this one's title
    /// class. `0` for a release-group id with no recorded affinity at all.
    pub fn count(&self, release_group_id: &str) -> i64 {
        self.class_of_group
            .get(release_group_id)
            .and_then(|class| self.class_total.get(class))
            .copied()
            .unwrap_or(0)
    }

    /// Whether `release_group_id` is the canonical member of its title class — the release
    /// [`select_release`] should prefer among several ids that are really the same album,
    /// so sibling tracks converge on one MBID and not merely one title.
    pub fn is_canonical(&self, release_group_id: &str) -> bool {
        self.class_of_group
            .get(release_group_id)
            .and_then(|class| self.canonical_of_class.get(class))
            .is_some_and(|canonical| canonical == release_group_id)
    }
}

/// `pub(crate)` (not just used by [`select_release`]) so `album::shortlist_candidates` can
/// rank candidate releases by the same Album/Single classification, rather than
/// hand-rolling a second, potentially-diverging copy of this check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ReleaseGroupKind {
    Album,
    Single,
    Other,
}

pub(crate) fn classify(group: &ReleaseGroup) -> ReleaseGroupKind {
    match group.primary_type.as_deref() {
        Some("Album") => ReleaseGroupKind::Album,
        Some("Single") => ReleaseGroupKind::Single,
        _ => ReleaseGroupKind::Other,
    }
}

/// A single MusicBrainz recording is typically attached to many releases — the
/// original studio album, but also singles, deluxe reissues, compilations,
/// soundtracks, and live albums that happen to include the same recording.
/// `releases.first()` picks whichever MusicBrainz happened to list first, which is
/// often a single or EP rather than the album a listener would actually expect
/// (observed directly: Arctic Monkeys tracks landing under "Body Paint" or "My
/// Propeller" — the singles those tracks were also released on — instead of the
/// studio albums "AM"/"Suck It and See" they're actually on).
///
/// Tries, in order:
/// 1. A release whose title matches `hint_album` (the file's own existing album
///    tag) exactly — the strongest signal available, and the only thing that
///    reliably fixes tracks whose *only* official-album-typed release in
///    MusicBrainz is actually a single (observed directly: Neck Deep's "December"
///    is linked to a "December" single release with `primary-type: Album`,
///    outranking the real "Life's Not Out to Get You" album release under the
///    type heuristic alone — nothing short of the file's own album tag
///    disambiguates that).
/// 2. The remaining candidates ranked by: Album-typed release-group beats
///    everything else (unlike the old `secondary_types.is_empty()` check this
///    replaced, a compilation like the Beatles' "1" — `primary-type: Album`,
///    `secondary-types: ["Compilation"]` — still counts as Album-typed here,
///    since excluding it was what caused every "1" track to fall through to its
///    own original single release instead); then the
///    title-consolidated release-group `affinity` has recorded the most existing
///    tracks for (see [`AffinityIndex`] — this is what lets a handful of
///    correctly-identified compilation tracks pull the rest of that artist's
///    stray tracks onto the same release, even when those tracks are scattered
///    across several release-group ids that are really the same album by title);
///    then whether this release-group is the
///    *canonical* member of its title class (see [`AffinityIndex::is_canonical`])
///    — this is what converges sibling tracks onto one specific MBID, not merely
///    one title, once the class total above has already picked a title; then an
///    "Official" release; then whichever release-group MusicBrainz listed first,
///    so ties resolve the same way every time.
/// 3. Whatever's first, so a track never goes unmatched for lack of a candidate
///    that passed the above.
pub fn select_release<'a>(
    releases: &'a [Release],
    hint_album: Option<&str>,
    affinity: &AffinityIndex,
) -> Option<&'a Release> {
    if let Some(hint_album) = hint_album.map(normalize).filter(|value| !value.is_empty())
        && let Some(matched) = releases
            .iter()
            .find(|release| release.title.as_deref().map(normalize) == Some(hint_album.clone()))
    {
        return Some(matched);
    }

    releases
        .iter()
        .enumerate()
        .max_by_key(|(index, release)| {
            let group = release.release_group.as_ref();
            let is_album = group.map(classify) == Some(ReleaseGroupKind::Album);
            let group_id = group.and_then(|group| group.id.as_deref());
            let affinity_count = group_id.map(|id| affinity.count(id)).unwrap_or(0);
            let is_class_canonical =
                group_id.is_some_and(|id| affinity.is_canonical(id));
            let is_official = release.status.as_deref() == Some("Official");
            (
                is_album,
                affinity_count,
                is_official,
                is_class_canonical,
                Reverse(*index),
            )
        })
        .map(|(_, release)| release)
}

fn normalize(value: impl AsRef<str>) -> String {
    crate::matching::normalize_matching_key(value)
}

/// Derives a small canonical genre list and up to 2 canonical mood tags from a
/// MusicBrainz recording's `genres`/`tags` folksonomy data, for driving auto-generated
/// playlists (e.g. a "relaxed" mood mix) from real per-track metadata rather than
/// fabricated categories.
///
/// `genres` (MusicBrainz's own curated subset) passes straight through, ranked by vote
/// count — these are already genre names, not free text. `tags` (the broader, uncurated
/// folksonomy — includes moods, scenes, and noise like "seen live" or "favorites"
/// alongside genre-ish terms) is matched against [`mood_for_tag`]'s keyword table instead,
/// since MusicBrainz has no dedicated mood vocabulary of its own.
pub fn canonicalize_tags(genres: &[MbTag], tags: &[MbTag]) -> (Vec<String>, Vec<String>) {
    let mut sorted_genres = genres.to_vec();
    sorted_genres.sort_by_key(|tag| Reverse(tag.count));
    let genre_names = sorted_genres
        .into_iter()
        .map(|tag| tag.name)
        .filter(|name| !name.trim().is_empty())
        .take(5)
        .collect();

    let mut sorted_tags = tags.to_vec();
    sorted_tags.sort_by_key(|tag| Reverse(tag.count));
    let mut moods: Vec<String> = Vec::new();
    for tag in &sorted_tags {
        if let Some(mood) = mood_for_tag(&tag.name)
            && !moods.iter().any(|existing| existing == mood)
        {
            moods.push(mood.to_string());
        }
        if moods.len() >= 2 {
            break;
        }
    }

    (genre_names, moods)
}

/// Keyword table mapping raw MusicBrainz folksonomy tag names to a small, fixed mood
/// vocabulary. Deliberately conservative — an unrecognized tag contributes no mood rather
/// than a guessed one, since a wrong mood is worse than a missing one for playlist
/// generation.
fn mood_for_tag(tag: &str) -> Option<&'static str> {
    const RELAXED: &[&str] = &[
        "chillout", "chill", "ambient", "mellow", "downtempo", "acoustic", "lo-fi", "lofi",
        "calm", "relaxing", "relaxed", "easy listening",
    ];
    const MELANCHOLY: &[&str] = &["sad", "melancholy", "melancholic", "moody", "wistful"];
    const ENERGETIC: &[&str] = &[
        "party", "dance", "upbeat", "energetic", "anthemic", "high energy", "banger",
        "workout",
    ];
    const FEELGOOD: &[&str] = &[
        "feel good", "feelgood", "summer", "happy", "uplifting", "sunny", "fun",
    ];

    let normalized = tag.trim().to_lowercase();
    if RELAXED.contains(&normalized.as_str()) {
        Some("relaxed")
    } else if MELANCHOLY.contains(&normalized.as_str()) {
        Some("mellow")
    } else if ENERGETIC.contains(&normalized.as_str()) {
        Some("energetic")
    } else if FEELGOOD.contains(&normalized.as_str()) {
        Some("feelgood")
    } else {
        None
    }
}

impl MusicBrainzClient {
    pub fn new(user_agent: String) -> Self {
        Self {
            http: reqwest::Client::new(),
            user_agent,
            limiter: RateLimiter::per_second(MAX_REQUESTS_PER_SECOND),
        }
    }

    pub async fn recording(&self, mbid: &str) -> Result<RecordingResponse, Error> {
        self.limiter.acquire().await;
        // `+media`: verified directly against the live API that this is what puts
        // `media[].track-count`/`track-offset` stubs onto each embedded release stub, at no
        // extra request — see `Release::media`'s doc comment. Absent without it.
        // `+genres+tags`: adds this recording's own curated genres and folksonomy tags (see
        // `RecordingResponse::genres`/`tags`) — free on this same request, feeds
        // `canonicalize_tags` for playlist mood/genre derivation.
        let url = format!(
            "https://musicbrainz.org/ws/2/recording/{mbid}?fmt=json&inc=artist-credits+releases+release-groups+media+genres+tags"
        );
        let response = self
            .http
            .get(url)
            .header(reqwest::header::USER_AGENT, self.user_agent.as_str())
            .send()
            .await?
            .error_for_status()?;
        Ok(response.json().await?)
    }

    /// Fetches a release's full ordered tracklist — see [`ReleaseResponse`]'s doc comment
    /// for why this is a separate call from [`Self::recording`], only made for a handful of
    /// shortlisted candidates rather than for every file.
    pub async fn release(&self, mbid: &str) -> Result<ReleaseResponse, Error> {
        self.limiter.acquire().await;
        let url = format!(
            "https://musicbrainz.org/ws/2/release/{mbid}?fmt=json&inc=recordings+artist-credits+release-groups"
        );
        let response = self
            .http
            .get(url)
            .header(reqwest::header::USER_AGENT, self.user_agent.as_str())
            .send()
            .await?
            .error_for_status()?;
        Ok(response.json().await?)
    }
}

/// The well-known Cover Art Archive front-cover redirect for a release — no separate
/// API call needed, this URL itself resolves (via redirect) to the image. Takes a
/// **release** MBID specifically (`Release::id`), not a release-group MBID — the
/// Cover Art Archive treats those as distinct ID namespaces under different URL
/// paths (`/release/{id}/front` vs `/release-group/{id}/front`); passing the wrong
/// one 404s.
pub fn cover_art_url(release_mbid: &str) -> String {
    format!("https://coverartarchive.org/release/{release_mbid}/front")
}

/// Fetches a release's front-cover image bytes from the Cover Art Archive, so
/// the caller can cache it into the hub's own blob store instead of every
/// client repeatedly hitting the archive directly (see `queue::cache_artwork`,
/// which is what actually does the caching — this is just the fetch).
/// `http` should follow redirects (`cover_art_url`'s `/front` path 302s to the
/// real image URL); `reqwest::Client`'s default does. Returns `None` on any
/// failure — no art, network error, non-2xx — since artwork is decorative and
/// never worth failing identification over.
pub async fn fetch_cover_art(
    http: &reqwest::Client,
    user_agent: &str,
    release_mbid: &str,
) -> Option<Vec<u8>> {
    let response = http
        .get(cover_art_url(release_mbid))
        .header(reqwest::header::USER_AGENT, user_agent)
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.bytes().await.ok().map(|bytes| bytes.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(
        id: &str,
        title: &str,
        status: Option<&str>,
        group_id: Option<&str>,
        primary_type: Option<&str>,
        secondary_types: &[&str],
    ) -> Release {
        Release {
            id: id.to_string(),
            title: Some(title.to_string()),
            status: status.map(str::to_string),
            release_group: group_id.map(|group_id| ReleaseGroup {
                id: Some(group_id.to_string()),
                primary_type: primary_type.map(str::to_string),
                secondary_types: secondary_types
                    .iter()
                    .map(|value| value.to_string())
                    .collect(),
                title: None,
            }),
            media: Vec::new(),
        }
    }

    /// The Beatles "1" case: no hint tag, and the compilation's release-group is
    /// `primary-type: Album` with `secondary-types: ["Compilation"]` — the old
    /// `secondary_types.is_empty()` check excluded it, so every track fell back to
    /// its own original single. It must now be picked over the single on type
    /// alone, with no affinity history required.
    #[test]
    fn prefers_compilation_album_over_single_with_no_affinity_history() {
        let releases = vec![
            release(
                "single-1",
                "Love Me Do",
                Some("Official"),
                Some("rg-single"),
                Some("Single"),
                &[],
            ),
            release(
                "comp-1",
                "1",
                Some("Official"),
                Some("rg-comp"),
                Some("Album"),
                &["Compilation"],
            ),
        ];

        let chosen = select_release(
            &releases,
            None,
            &AffinityIndex::default(),
        );

        assert_eq!(chosen.map(|release| release.id.as_str()), Some("comp-1"));
    }

    /// The Neck Deep "December" case: MusicBrainz mistags the single's
    /// release-group as `primary-type: Album`, so type-based ranking alone can't
    /// tell it apart from the real album — only the file's own hint tag can, and it
    /// must win.
    #[test]
    fn hint_tag_wins_even_when_a_single_is_mistyped_as_an_album() {
        let releases = vec![
            release(
                "single-december",
                "December",
                Some("Official"),
                Some("rg-december"),
                Some("Album"),
                &[],
            ),
            release(
                "album-real",
                "Life's Not Out to Get You",
                Some("Official"),
                Some("rg-real"),
                Some("Album"),
                &[],
            ),
        ];

        let chosen = select_release(
            &releases,
            Some("Life's Not Out to Get You"),
            &AffinityIndex::default(),
        );

        assert_eq!(
            chosen.map(|release| release.id.as_str()),
            Some("album-real")
        );
    }

    /// When two Album-typed candidates tie on type and official status, the one
    /// with more of this artist's tracks already
    /// attributed to it (via `affinity`) wins — the "bulk allocate to the album
    /// once there's enough evidence" behavior.
    #[test]
    fn prefers_the_release_group_with_more_affinity() {
        let releases = vec![
            release(
                "studio-1",
                "Life's Not Out to Get You",
                Some("Official"),
                Some("rg-studio"),
                Some("Album"),
                &[],
            ),
            release(
                "comp-1",
                "Greatest Hits",
                Some("Official"),
                Some("rg-comp"),
                Some("Album"),
                &[],
            ),
        ];
        let affinity = AffinityIndex::from_counts([("rg-comp".to_string(), 5)]);

        let chosen = select_release(&releases, None, &affinity);

        assert_eq!(chosen.map(|release| release.id.as_str()), Some("comp-1"));
    }

    /// No candidate release-group at all (e.g. a bare single with no MusicBrainz
    /// release-group data) still returns a usable release rather than `None`.
    #[test]
    fn falls_back_to_first_release_when_nothing_ranks_above_it() {
        let releases = vec![release("only-1", "Untitled Release", None, None, None, &[])];

        let chosen = select_release(
            &releases,
            None,
            &AffinityIndex::default(),
        );

        assert_eq!(chosen.map(|release| release.id.as_str()), Some("only-1"));
    }

    /// The motivating case: three distinct release-group ids, all titled "The Beatles"
    /// (observed directly in the real affinity table), split a single artist's evidence
    /// across three weaker signals under plain per-id affinity. Consolidated by title, the
    /// class total lets the group beat a same-typed rival release-group it otherwise
    /// wouldn't outrank on a per-id count alone.
    #[test]
    fn select_release_prefers_the_class_with_more_consolidated_affinity() {
        let releases = vec![
            release(
                "rival-1",
                "Abbey Road",
                Some("Official"),
                Some("rg-rival"),
                Some("Album"),
                &[],
            ),
            release(
                "beatles-3",
                "The Beatles",
                Some("Official"),
                Some("rg-beatles-3"),
                Some("Album"),
                &[],
            ),
        ];
        let affinity = AffinityIndex::from_rows(&[
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-beatles-1".to_string(),
                release_title: Some("The Beatles".to_string()),
                track_count: 3,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-beatles-2".to_string(),
                release_title: Some("The Beatles".to_string()),
                track_count: 3,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-beatles-3".to_string(),
                release_title: Some("The Beatles".to_string()),
                track_count: 3,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-rival".to_string(),
                release_title: Some("Abbey Road".to_string()),
                track_count: 8,
            },
        ]);

        // Per-id, `rg-rival` (8) beats any single Beatles id (3) — but the three Beatles
        // rows consolidate to a class total of 9, which must win instead.
        let chosen = select_release(&releases, None, &affinity);

        assert_eq!(chosen.map(|release| release.id.as_str()), Some("beatles-3"));
    }

    /// Within the winning title class, the canonical member (highest individual count) must
    /// be preferred over a same-typed, same-official rival release-group id that shares the
    /// class but individually has less evidence — this is what converges sibling tracks onto
    /// one specific MBID, not merely one title.
    #[test]
    fn select_release_prefers_the_canonical_group_within_the_winning_class() {
        let releases = vec![
            release(
                "beatles-a",
                "The Beatles",
                Some("Official"),
                Some("rg-beatles-a"),
                Some("Album"),
                &[],
            ),
            release(
                "beatles-b",
                "The Beatles",
                Some("Official"),
                Some("rg-beatles-b"),
                Some("Album"),
                &[],
            ),
        ];
        let affinity = AffinityIndex::from_rows(&[
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-beatles-a".to_string(),
                release_title: Some("The Beatles".to_string()),
                track_count: 2,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-beatles-b".to_string(),
                release_title: Some("The Beatles".to_string()),
                track_count: 6,
            },
        ]);

        let chosen = select_release(&releases, None, &affinity);

        assert_eq!(chosen.map(|release| release.id.as_str()), Some("beatles-b"));
    }

    /// Unicode-variant apostrophes/dashes in the affinity title must consolidate exactly
    /// like the release-group-id case above — the whole point of consolidating by
    /// `normalize_matching_key`-normalized title rather than raw string equality.
    #[test]
    fn select_release_consolidates_affinity_across_unicode_hyphen_title_variants() {
        let releases = vec![
            release(
                "rival-1",
                "Untitled EP",
                Some("Official"),
                Some("rg-rival"),
                Some("Album"),
                &[],
            ),
            release(
                "blink-b",
                "blink\u{2010}182",
                Some("Official"),
                Some("rg-blink-b"),
                Some("Album"),
                &[],
            ),
        ];
        let affinity = AffinityIndex::from_rows(&[
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-blink-a".to_string(),
                release_title: Some("blink-182".to_string()), // ASCII hyphen
                track_count: 4,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-blink-b".to_string(),
                release_title: Some("blink\u{2010}182".to_string()), // U+2010 hyphen
                track_count: 4,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-rival".to_string(),
                release_title: Some("Untitled EP".to_string()),
                track_count: 5,
            },
        ]);

        // Consolidated class total for "blink-182" is 8 (4 + 4 across two glyph variants),
        // which must beat the rival's un-consolidated 5.
        let chosen = select_release(&releases, None, &affinity);

        assert_eq!(chosen.map(|release| release.id.as_str()), Some("blink-b"));
    }

    /// Rows with no title can't be matched against anything else and must not silently
    /// merge into one giant "untitled" class.
    #[test]
    fn untitled_affinity_rows_stay_their_own_class() {
        let index = AffinityIndex::from_rows(&[
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-a".to_string(),
                release_title: None,
                track_count: 3,
            },
            aro_sync_store::ReleaseGroupAffinityRow {
                release_group_id: "rg-b".to_string(),
                release_title: None,
                track_count: 5,
            },
        ]);

        assert_eq!(index.count("rg-a"), 3);
        assert_eq!(index.count("rg-b"), 5);
        assert!(index.is_canonical("rg-a"));
        assert!(index.is_canonical("rg-b"));
    }

    fn tag(name: &str, count: u32) -> MbTag {
        MbTag {
            name: name.to_string(),
            count,
        }
    }

    #[test]
    fn canonicalize_tags_ranks_genres_by_count_and_caps_at_five() {
        let genres = vec![
            tag("shoegaze", 2),
            tag("dream pop", 9),
            tag("indie rock", 5),
            tag("noise pop", 4),
            tag("alternative rock", 3),
            tag("britpop", 1),
        ];

        let (genre_names, _) = canonicalize_tags(&genres, &[]);

        assert_eq!(
            genre_names,
            vec!["dream pop", "indie rock", "noise pop", "alternative rock", "shoegaze"]
        );
    }

    #[test]
    fn canonicalize_tags_maps_folksonomy_tags_to_known_moods() {
        let tags = vec![tag("chillout", 10), tag("seen live", 20), tag("summer", 3)];

        let (_, moods) = canonicalize_tags(&[], &tags);

        assert_eq!(moods, vec!["relaxed".to_string(), "feelgood".to_string()]);
    }

    #[test]
    fn canonicalize_tags_ignores_unrecognized_tags_and_caps_at_two_moods() {
        let tags = vec![
            tag("party", 10),
            tag("favorites", 9),
            tag("sad", 8),
            tag("upbeat", 7),
        ];

        let (_, moods) = canonicalize_tags(&[], &tags);

        // "party" and "sad" are the two highest-count recognized tags; "upbeat" (also
        // "energetic") is dropped once two moods are already collected, and the
        // unrecognized "favorites" tag never contributes.
        assert_eq!(moods, vec!["energetic".to_string(), "mellow".to_string()]);
    }

    #[test]
    fn canonicalize_tags_returns_empty_when_nothing_recognized() {
        let tags = vec![tag("favorites", 5), tag("seen live", 3)];

        let (genre_names, moods) = canonicalize_tags(&[], &tags);

        assert!(genre_names.is_empty());
        assert!(moods.is_empty());
    }
}
