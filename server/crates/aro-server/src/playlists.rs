//! Server-side auto-playlist generation — the hub derives playlists from its own
//! canonical analytics (synced `listening_events`, CRDT favourites, MusicBrainz mood
//! tags from background identification) and serves them to every client, keyed by
//! content hash. Clients only map hashes to their local catalogs and render; they never
//! generate. This keeps every device seeing the same playlists, and keeps the BI that
//! drives them on the hub, which is the durable, canonical copy of everything else too.
//!
//! Tier 1 of `listening-intelligence-roadmap.md`: behavioural signals (decayed
//! affinity, skip rate, time-of-day, first-seen) layered onto the Tier-0 recipes
//! already shipped (favourites, MusicBrainz mood tags).

use aro_sync_store::{ListeningEventSummary, PlaylistSeeds};
use chrono::{DateTime, Datelike, Utc, Weekday};
use serde::Serialize;

/// Playlists with fewer songs than this are dropped entirely — a "playlist" of 1-2
/// tracks reads as broken rather than useful.
const MINIMUM_TRACK_COUNT: usize = 3;
const MAXIMUM_TRACK_COUNT: usize = 30;

/// Mood tags recognized for playlist generation, in the fixed order they're considered —
/// must match the vocabulary `aro_track_id::musicbrainz::canonicalize_tags` can produce.
const MOOD_ORDER: [&str; 4] = ["relaxed", "energetic", "feelgood", "mellow"];

/// Lower bound for "well played", for a listener whose history is too short for a
/// percentile to mean anything. Everything above this is relative — see [`ListeningScale`].
const FORGOTTEN_MIN_PLAYS_FLOOR: i64 = 3;
const FORGOTTEN_MIN_DAYS_SINCE_PLAY: f64 = 90.0;

/// Thresholds taken from the listener's own distribution rather than fixed counts.
///
/// A fixed threshold only suits one size of library. "Played at least three times" picks
/// out a handful of tracks for someone with a hundred plays and very nearly the entire
/// library for someone with a million — and a shelf that matches everything is exactly as
/// useless as one that matches nothing, while failing silently in both directions.
///
/// Percentiles hold their meaning at any scale: the top quartile of what *this* listener
/// plays is a real distinction whether that means four plays or four hundred. A floor keeps
/// small histories sane, where a percentile of a handful of plays is noise.
struct ListeningScale {
    /// Non-zero lifetime play counts, ascending.
    play_counts: Vec<i64>,
}

impl ListeningScale {
    fn from_seeds(seeds: &PlaylistSeeds) -> Self {
        let mut play_counts: Vec<i64> = seeds
            .listening
            .values()
            .map(|summary| summary.play_count)
            .filter(|count| *count > 0)
            .collect();
        play_counts.sort_unstable();
        Self { play_counts }
    }

    /// Nearest-rank percentile of the play-count distribution, `0.0..=1.0`.
    fn percentile(&self, fraction: f64) -> i64 {
        if self.play_counts.is_empty() {
            return 0;
        }
        let rank = ((self.play_counts.len() as f64 - 1.0) * fraction.clamp(0.0, 1.0)).round();
        self.play_counts[rank as usize]
    }

    /// What counts as well played *for this listener*: more played than half of what they
    /// play at all. The floor stops a library with a few dozen plays treating a single play
    /// as a favourite.
    ///
    /// The median rather than an upper quartile, because a quartile is defined by the
    /// listener's very heaviest tracks — on a library with a few hot records and a long
    /// tail of loved ones, a p75 bar excludes the loved tail entirely and empties the
    /// shelf. The median asks "played more than most", which is the actual question.
    fn well_played(&self) -> i64 {
        self.percentile(0.5).max(FORGOTTEN_MIN_PLAYS_FLOOR)
    }

    /// Enough plays for a proportion of them to be evidence rather than coincidence.
    /// Lower than [`Self::well_played`]: this gates *shape* (when a track is played), not
    /// *strength*, so it only has to rule out the single data point.
    fn representative(&self) -> i64 {
        self.percentile(0.25).max(TIME_OF_DAY_MIN_PLAYS_FLOOR)
    }
}

/// A track first seen within this many days, with at most one play, is a "fresh find".
const FRESH_MAX_DAYS: i64 = 30;
const FRESH_MAX_PLAYS: i64 = 1;

/// A track needs at least this many plays, with at least this fraction of them
/// falling in a given local-time window, to represent that window meaningfully —
/// otherwise a track played once at 3am would swing "Late Night" on a single data
/// point.
const TIME_OF_DAY_MIN_PLAYS_FLOOR: i64 = 2;
const TIME_OF_DAY_MIN_FRACTION: f64 = 0.5;
/// Local hour-of-day windows (24h clock) for the two time-of-day playlists.
const MORNING_HOURS: [u32; 6] = [5, 6, 7, 8, 9, 10];
const LATE_NIGHT_HOURS: [u32; 7] = [22, 23, 0, 1, 2, 3, 4];

/// An album needs at least this many owned tracks to count as a real "album" rather
/// than a stray single, and is "lost" once it's gone at least this many days without
/// a play (or has never been played at all).
const LOST_ALBUM_MIN_TRACKS: usize = 3;
const LOST_ALBUM_MIN_DAYS_SINCE_PLAY: f64 = 60.0;

/// A track needs at least this many lifetime plays to have been genuinely loved, and
/// its *most recent* play needs to be at least this many years ago to count as
/// dormant enough for "Time Capsule" — a track played 3 times last month has plays,
const TIME_CAPSULE_MIN_YEARS_AGO: i32 = 2;

/// What a [`GeneratedPlaylist`] represents, so clients can route it to the right Home
/// section without parsing `id` prefixes. `id` stays the stable per-playlist identity
/// (selection, detail-view routing); `kind` is purely a presentation hint.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaylistKind {
    /// Catch-all curated recipe (favourites, heavy rotation, forgotten favourites,
    /// fresh finds, time-of-day, deep cuts) — the existing "Made for You" grid.
    ForYou,
    RecentlyPlayedTrack,
    RecentlyPlayedAlbum,
    Mood,
    /// "More From `<Artist>`" — an artist the listener has played recently.
    ArtistMix,
    /// All-time top artist by lifetime play count.
    FavouriteArtist,
    HitsByYear,
    ReplayMonth,
    ReplayAllTime,
    /// An album the listener owns but hasn't played in a while (or ever) —
    /// "Lost Albums".
    LostAlbum,
    /// Tracks with meaningful lifetime plays that have gone dormant for at least
    /// [`TIME_CAPSULE_MIN_YEARS_AGO`] years — "Time Capsule".
    TimeCapsule,
}

/// One generated playlist. `content_hashes` (not track ids) because content hash is the
/// only identifier client libraries share with the hub — a client maps them onto its own
/// catalog and simply drops hashes it doesn't hold locally.
#[derive(Clone, Debug, Serialize)]
pub struct GeneratedPlaylist {
    /// Stable slug (e.g. `"heavy-rotation"`, `"mood-relaxed"`) for client view identity.
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub content_hashes: Vec<String>,
    pub kind: PlaylistKind,
    /// Seconds since epoch of the most recent play among `content_hashes`, or `None` if
    /// none of them have ever been played — lets a client build a "recently played"
    /// section out of *any* kind of playlist without a separate query.
    pub last_played_at: Option<f64>,
}

/// `utc_offset_minutes` is the requesting client's local UTC offset (positive east of
/// UTC) — used only to bucket [`ListeningEventSummary::hour_histogram`] (recorded in
/// UTC) into *that listener's* morning/late-night windows, not the hub's. Different
/// devices in different timezones therefore see different Morning/Late Night mixes,
/// which is the whole point of the feature; every other playlist is timezone-agnostic.
pub fn generate(
    seeds: &PlaylistSeeds,
    now: DateTime<Utc>,
    utc_offset_minutes: i32,
) -> Vec<GeneratedPlaylist> {
    let seed = daily_seed(now);
    let mut playlists = Vec::new();

    push(
        &mut playlists,
        seeds,
        PlaylistKind::ForYou,
        "recently-loved",
        "Recently Loved",
        "Your favourites",
        seeds
            .tracks
            .iter()
            .filter(|track| track.favourite)
            .map(|track| track.content_hash.clone())
            .collect(),
    );

    push(
        &mut playlists,
        seeds,
        PlaylistKind::ForYou,
        "heavy-rotation",
        "Heavy Rotation",
        "In heavy rotation lately",
        ranked_by(seeds, |summary| summary.decayed_affinity),
    );

    for (index, mood) in MOOD_ORDER.iter().enumerate() {
        let mut hashes: Vec<String> = seeds
            .tracks
            .iter()
            .filter(|track| track.mood_tags.iter().any(|tag| tag == mood))
            .map(|track| track.content_hash.clone())
            .collect();
        if hashes.is_empty() {
            continue;
        }
        shuffle(&mut hashes, seed.wrapping_add(index as u64));
        let (title, subtitle) = mood_presentation(mood, now);
        push(
            &mut playlists,
            seeds,
            PlaylistKind::Mood,
            &format!("mood-{mood}"),
            title,
            subtitle,
            hashes,
        );
    }

    push(
        &mut playlists,
        seeds,
        PlaylistKind::RecentlyPlayedTrack,
        "recently-played",
        "Recently Played",
        "Pick up where you left off",
        ranked_by(seeds, |summary| summary.last_played_at),
    );

    push(
        &mut playlists,
        seeds,
        PlaylistKind::ForYou,
        "forgotten-favourites",
        "Forgotten Favourites",
        "You used to love these",
        forgotten_favourites(seeds, now),
    );

    push(
        &mut playlists,
        seeds,
        PlaylistKind::ForYou,
        "fresh-finds",
        "Fresh Finds",
        "Recently added, barely played",
        fresh_finds(seeds, now),
    );

    for (id, title, subtitle, hours) in [
        (
            "morning-rotation",
            "Morning Rotation",
            "What you play in the morning",
            &MORNING_HOURS[..],
        ),
        (
            "late-night",
            "Late Night",
            "Your late-night listening",
            &LATE_NIGHT_HOURS[..],
        ),
    ] {
        let mut hashes = time_of_day(seeds, hours, utc_offset_minutes);
        shuffle(&mut hashes, seed.wrapping_add(id.len() as u64));
        push(
            &mut playlists,
            seeds,
            PlaylistKind::ForYou,
            id,
            title,
            subtitle,
            hashes,
        );
    }

    let mut deep_cuts: Vec<String> = seeds
        .tracks
        .iter()
        .filter(|track| !seeds.listening.contains_key(&track.content_hash))
        .map(|track| track.content_hash.clone())
        .collect();
    shuffle(&mut deep_cuts, seed);
    push(
        &mut playlists,
        seeds,
        PlaylistKind::ForYou,
        "deep-cuts",
        "Deep Cuts",
        "Rarely played",
        deep_cuts,
    );

    push_recently_played_albums(&mut playlists, seeds);
    push_artist_sections(&mut playlists, seeds);
    push_hits_by_year(&mut playlists, seeds);
    push_replay(&mut playlists, seeds, now);
    push_measured_mixes(&mut playlists, seeds);
    push_daily_mixes(&mut playlists, seeds, seed);
    push_lost_albums(&mut playlists, seeds, now);
    push_time_capsule(&mut playlists, seeds, now);

    playlists
}

/// Per-artist play aggregate, built once and reused by "More From `<Artist>`" and
/// "Favourite Artists" — both are the same underlying shape (an artist's full catalog,
/// ranked by affinity), just selected and titled differently.
struct ArtistAggregate {
    artist: String,
    /// Every track by this artist, in catalog order — not just played ones, so "More
    /// From X" can surface deep cuts the listener hasn't gotten to yet.
    content_hashes: Vec<String>,
    lifetime_plays: i64,
    decayed_affinity: f64,
    /// Distinct non-empty album names among this artist's tracks — an artist with
    /// only one (or zero known) album can't produce a visually varied mix no matter
    /// how the client orders its tiles, so this drives the preference in
    /// [`push_artist_sections`] rather than being purely a display concern.
    album_count: usize,
}

/// One artist's running totals while aggregating: name, the content hashes seen for them,
/// play count, listened seconds, and the distinct albums those plays came from.
type ArtistTally = (
    String,
    Vec<String>,
    i64,
    f64,
    std::collections::HashSet<String>,
);

fn artist_aggregates(seeds: &PlaylistSeeds) -> Vec<ArtistAggregate> {
    let mut by_artist: Vec<ArtistTally> = Vec::new();
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for track in &seeds.tracks {
        let Some(artist) = track.artist.as_ref().filter(|a| !a.is_empty()) else {
            continue;
        };
        let summary = seeds.listening.get(&track.content_hash);
        let slot = *index.entry(artist.clone()).or_insert_with(|| {
            by_artist.push((
                artist.clone(),
                Vec::new(),
                0,
                0.0,
                std::collections::HashSet::new(),
            ));
            by_artist.len() - 1
        });
        by_artist[slot].1.push(track.content_hash.clone());
        by_artist[slot].2 += summary.map(|s| s.play_count).unwrap_or(0);
        by_artist[slot].3 += summary.map(|s| s.decayed_affinity).unwrap_or(0.0);
        if let Some(album) = track.album.as_ref().filter(|a| !a.is_empty()) {
            by_artist[slot].4.insert(album.clone());
        }
    }
    by_artist
        .into_iter()
        .map(
            |(artist, content_hashes, lifetime_plays, decayed_affinity, albums)| ArtistAggregate {
                artist,
                content_hashes,
                lifetime_plays,
                decayed_affinity,
                album_count: albums.len(),
            },
        )
        .collect()
}

/// "More From `<Artist>`" (top 2 artists by recent listening) and "Favourite Artists"
/// (top 8 by lifetime plays) — both drawn from the same [`artist_aggregates`].
fn push_artist_sections(playlists: &mut Vec<GeneratedPlaylist>, seeds: &PlaylistSeeds) {
    let aggregates = artist_aggregates(seeds);

    let mut by_recent: Vec<&ArtistAggregate> = aggregates
        .iter()
        .filter(|a| a.decayed_affinity > 0.0)
        .collect();
    // Prefer artists with more than one known album first — an artist with a single
    // album (or none known) can't produce a visually varied "More From X" mosaic no
    // matter how the tracks are ordered, so this is a ranking preference (not a hard
    // filter) ahead of the existing recency-based ranking.
    by_recent.sort_by(|a, b| {
        (b.album_count > 1)
            .cmp(&(a.album_count > 1))
            .then_with(|| b.decayed_affinity.total_cmp(&a.decayed_affinity))
            .then_with(|| a.artist.cmp(&b.artist))
    });
    for (index, artist) in by_recent.into_iter().take(2).enumerate() {
        push(
            playlists,
            seeds,
            PlaylistKind::ArtistMix,
            &format!("artist-mix-{index}-{}", slugify(&artist.artist)),
            &format!("More From {}", artist.artist),
            "Because you've been playing them lately",
            order_by_affinity(seeds, &artist.content_hashes),
        );
    }

    let mut by_lifetime: Vec<&ArtistAggregate> =
        aggregates.iter().filter(|a| a.lifetime_plays > 0).collect();
    by_lifetime.sort_by(|a, b| {
        b.lifetime_plays
            .cmp(&a.lifetime_plays)
            .then_with(|| a.artist.cmp(&b.artist))
    });
    for (index, artist) in by_lifetime.into_iter().take(8).enumerate() {
        push(
            playlists,
            seeds,
            PlaylistKind::FavouriteArtist,
            &format!("favourite-artist-{index}-{}", slugify(&artist.artist)),
            &artist.artist,
            "Favourite artist",
            order_by_affinity(seeds, &artist.content_hashes),
        );
    }
}

/// Albums with at least one track played recently — "Recently Played Albums", ranked by
/// the most recent play among each album's tracks. Tracks within an album keep catalog
/// order (no track-number field to sort by, but that's usually close enough for a
/// freshly scanned rip).
fn push_recently_played_albums(playlists: &mut Vec<GeneratedPlaylist>, seeds: &PlaylistSeeds) {
    struct AlbumAggregate {
        album: String,
        artist: Option<String>,
        content_hashes: Vec<String>,
        last_played_at: f64,
    }
    let mut by_album: Vec<AlbumAggregate> = Vec::new();
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for track in &seeds.tracks {
        let Some(album) = track.album.as_ref().filter(|a| !a.is_empty()) else {
            continue;
        };
        let Some(summary) = seeds.listening.get(&track.content_hash) else {
            continue;
        };
        let slot = *index.entry(album.clone()).or_insert_with(|| {
            by_album.push(AlbumAggregate {
                album: album.clone(),
                artist: track.artist.clone(),
                content_hashes: Vec::new(),
                last_played_at: 0.0,
            });
            by_album.len() - 1
        });
        by_album[slot]
            .content_hashes
            .push(track.content_hash.clone());
        by_album[slot].last_played_at = by_album[slot].last_played_at.max(summary.last_played_at);
    }
    by_album.sort_by(|a, b| {
        b.last_played_at
            .total_cmp(&a.last_played_at)
            .then_with(|| a.album.cmp(&b.album))
    });
    for (index, album) in by_album.into_iter().take(8).enumerate() {
        push(
            playlists,
            seeds,
            PlaylistKind::RecentlyPlayedAlbum,
            &format!("recently-played-album-{index}-{}", slugify(&album.album)),
            &album.album,
            album.artist.as_deref().unwrap_or("Album"),
            album.content_hashes,
        );
    }
}

/// Albums the listener owns but hasn't returned to in a while (or ever) — "Lost
/// Albums". Unlike [`push_recently_played_albums`], every track counts toward an
/// album's membership regardless of whether it's ever been played — an album with
/// zero plays at all is the most "lost" of all, not excluded the way an unplayed
/// track is excluded from "Recently Played Albums".
fn push_lost_albums(
    playlists: &mut Vec<GeneratedPlaylist>,
    seeds: &PlaylistSeeds,
    now: DateTime<Utc>,
) {
    struct AlbumAggregate {
        album: String,
        content_hashes: Vec<String>,
        last_played_at: Option<f64>,
    }
    let mut by_album: Vec<AlbumAggregate> = Vec::new();
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for track in &seeds.tracks {
        let Some(album) = track.album.as_ref().filter(|a| !a.is_empty()) else {
            continue;
        };
        let slot = *index.entry(album.clone()).or_insert_with(|| {
            by_album.push(AlbumAggregate {
                album: album.clone(),
                content_hashes: Vec::new(),
                last_played_at: None,
            });
            by_album.len() - 1
        });
        by_album[slot]
            .content_hashes
            .push(track.content_hash.clone());
        if let Some(summary) = seeds.listening.get(&track.content_hash) {
            by_album[slot].last_played_at = Some(
                by_album[slot]
                    .last_played_at
                    .map_or(summary.last_played_at, |max: f64| {
                        max.max(summary.last_played_at)
                    }),
            );
        }
    }
    let now_secs = now.timestamp() as f64;
    let mut lost: Vec<AlbumAggregate> = by_album
        .into_iter()
        .filter(|album| album.content_hashes.len() >= LOST_ALBUM_MIN_TRACKS)
        .filter(|album| {
            album.last_played_at.is_none_or(|last_played_at| {
                (now_secs - last_played_at) / 86_400.0 >= LOST_ALBUM_MIN_DAYS_SINCE_PLAY
            })
        })
        .collect();
    // Never-played (or longest-dormant) albums first; tie-break by track count, since
    // a richer album is more clearly worth surfacing than a stray couple of tracks.
    lost.sort_by(|a, b| {
        a.last_played_at
            .unwrap_or(f64::NEG_INFINITY)
            .total_cmp(&b.last_played_at.unwrap_or(f64::NEG_INFINITY))
            .then_with(|| b.content_hashes.len().cmp(&a.content_hashes.len()))
            .then_with(|| a.album.cmp(&b.album))
    });
    for (index, album) in lost.into_iter().take(8).enumerate() {
        push(
            playlists,
            seeds,
            PlaylistKind::LostAlbum,
            &format!("lost-album-{index}-{}", slugify(&album.album)),
            &album.album,
            "Haven't visited this one in a while",
            album.content_hashes,
        );
    }
}

/// "Time Capsule" — tracks with meaningful lifetime plays whose *most recent* play
/// was at least [`TIME_CAPSULE_MIN_YEARS_AGO`] years ago: genuinely loved once,
/// dormant since. A single mixed-track nostalgia playlist rather than per-year,
/// since there's rarely enough dormant-but-loved history to usefully split further.
fn push_time_capsule(
    playlists: &mut Vec<GeneratedPlaylist>,
    seeds: &PlaylistSeeds,
    now: DateTime<Utc>,
) {
    let current_year = now.year();
    let well_played = ListeningScale::from_seeds(seeds).well_played();
    let mut candidates: Vec<(&str, i64, i32)> = seeds
        .listening
        .iter()
        .filter(|(_, summary)| summary.play_count >= well_played)
        .filter_map(|(hash, summary)| {
            let last_played_year = summary.last_played_year?;
            (current_year - last_played_year >= TIME_CAPSULE_MIN_YEARS_AGO).then_some((
                hash.as_str(),
                summary.play_count,
                last_played_year,
            ))
        })
        .collect();
    // Most-played first (genuinely loved), then longest-dormant as a tie-break.
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
    let hashes = candidates
        .into_iter()
        .map(|(hash, _, _)| hash.to_string())
        .collect();
    push(
        playlists,
        seeds,
        PlaylistKind::TimeCapsule,
        "time-capsule",
        "Time Capsule",
        "Music you loved a while back",
        hashes,
    );
}

/// "Hits of `<year>`" — the top 3 release years by aggregate recent listening, each
/// showing that year's most-played tracks. Only tracks that have actually been played
/// qualify (an unplayed track isn't a "hit"), which also means a year with plenty of
/// A track considered for a year's playlist: content hash, play count, listened seconds,
/// and album.
type YearlyTrack<'a> = (&'a String, i64, f64, Option<&'a String>);

/// library coverage but no listening simply won't appear.
fn push_hits_by_year(playlists: &mut Vec<GeneratedPlaylist>, seeds: &PlaylistSeeds) {
    let mut by_year: std::collections::HashMap<i64, Vec<YearlyTrack<'_>>> =
        std::collections::HashMap::new();
    for track in &seeds.tracks {
        let Some(year) = track.release_year else {
            continue;
        };
        let Some(summary) = seeds.listening.get(&track.content_hash) else {
            continue;
        };
        by_year.entry(year).or_default().push((
            &track.content_hash,
            summary.play_count,
            summary.decayed_affinity,
            track.artist.as_ref().filter(|a| !a.is_empty()),
        ));
    }
    // Rank years by a (has-more-than-one-artist, total affinity) preference — a year
    // dominated by a single artist can't produce a visually varied cover mosaic, so
    // years with multiple distinct artists are preferred ahead of the existing
    // affinity-based ranking (a preference, not a hard filter: a single-artist year
    // still wins out over having no year at all).
    let mut years: Vec<(i64, f64, bool)> = by_year
        .iter()
        .map(|(year, tracks)| {
            let total_affinity = tracks.iter().map(|(_, _, affinity, _)| affinity).sum();
            let distinct_artists: std::collections::HashSet<&String> = tracks
                .iter()
                .filter_map(|(_, _, _, artist)| *artist)
                .collect();
            (*year, total_affinity, distinct_artists.len() > 1)
        })
        .collect();
    years.sort_by(|a, b| {
        b.2.cmp(&a.2)
            .then_with(|| b.1.total_cmp(&a.1))
            .then_with(|| b.0.cmp(&a.0))
    });

    for (year, _, _) in years.into_iter().take(3) {
        let mut tracks = by_year.remove(&year).unwrap_or_default();
        tracks.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        let hashes = tracks
            .into_iter()
            .map(|(hash, _, _, _)| hash.clone())
            .collect();
        push(
            playlists,
            seeds,
            PlaylistKind::HitsByYear,
            &format!("hits-{year}"),
            &format!("Hits of {year}"),
            "Your most-played tracks from that year",
            hashes,
        );
    }
}

/// "Your `<Month>` Replay" (this calendar month's top tracks) and "Replay All Time"
/// (lifetime top tracks by raw play count — distinct from Heavy Rotation, which ranks
/// by decayed affinity so it drifts toward *recent* favourites; Replay is a lifetime
/// tally, closer to a "most played ever" list).
fn push_replay(playlists: &mut Vec<GeneratedPlaylist>, seeds: &PlaylistSeeds, now: DateTime<Utc>) {
    let mut this_month: Vec<(&String, i64)> = seeds
        .listening
        .iter()
        .filter(|(_, summary)| summary.current_month_play_count > 0)
        .map(|(hash, summary)| (hash, summary.current_month_play_count))
        .collect();
    this_month.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    push(
        playlists,
        seeds,
        PlaylistKind::ReplayMonth,
        "replay-month",
        &format!("Your {} Replay", now.format("%B")),
        "This month's most-played tracks",
        this_month
            .into_iter()
            .map(|(hash, _)| hash.clone())
            .collect(),
    );

    let mut all_time: Vec<(&String, i64)> = seeds
        .listening
        .iter()
        .map(|(hash, summary)| (hash, summary.play_count))
        .collect();
    all_time.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    push(
        playlists,
        seeds,
        PlaylistKind::ReplayAllTime,
        "replay-all-time",
        "Replay All Time",
        "Your most-played tracks, ever",
        all_time.into_iter().map(|(hash, _)| hash.clone()).collect(),
    );
}

// --- Tier 2/3 (listening-intelligence-roadmap.md): measured audio features -------

/// Below this measured tempo, a track counts as "Workout"-eligible.
const WORKOUT_MIN_TEMPO_BPM: f64 = 120.0;
/// RMS energy threshold for "Workout" — both this and tempo must clear their bar.
const WORKOUT_MIN_ENERGY: f64 = 0.08;
const CHILL_MAX_TEMPO_BPM: f64 = 95.0;
const CHILL_MAX_ENERGY: f64 = 0.06;
/// Normalized spectral centroid ceiling (see `AudioFeatures::brightness`) for "Chill" —
/// keeps a fast but dark/ambient track out of a mix meant to feel bright and driving,
/// and vice versa.
const CHILL_MAX_BRIGHTNESS: f64 = 0.35;

const DAILY_MIX_COUNT: usize = 4;
/// k-means needs enough analyzed tracks for `DAILY_MIX_COUNT` clusters to mean
/// anything — below this, Daily Mixes are skipped entirely rather than generating
/// clusters of 2-3 tracks each.
const DAILY_MIX_MIN_TRACKS: usize = DAILY_MIX_COUNT * 8;
const KMEANS_ITERATIONS: usize = 12;

/// A track that's been skipped more than this fraction of its plays is excluded from
/// radio results — a heavily skipped track isn't a good "more like this" suggestion
/// even if it's timbrally similar to the seed.
const RADIO_MAX_SKIP_RATE: f64 = 0.7;
pub const RADIO_DEFAULT_LIMIT: usize = 30;

fn decoded_features(
    track: &aro_sync_store::PlaylistSeedTrack,
) -> Option<aro_track_id::audio_features::AudioFeatures> {
    serde_json::from_str(track.audio_features_json.as_ref()?).ok()
}

/// "Workout Mix" and "Wind Down" — Tier 2's measured counterparts to the Tier 1/
/// MusicBrainz-tagged mood mixes (`mood-energetic`/`mood-relaxed`): these use tempo
/// and RMS energy actually measured from the audio (see `aro_track_id::audio_features`),
/// not folksonomy tags, so they exist independently of whether a track has been
/// identified. Ordered by tempo ascending — a mix that flows from its slowest to
/// fastest track rather than jumping around, per the roadmap's "tempo-coherent
/// ordering" goal.
fn push_measured_mixes(playlists: &mut Vec<GeneratedPlaylist>, seeds: &PlaylistSeeds) {
    push(
        playlists,
        seeds,
        PlaylistKind::ForYou,
        "workout-measured",
        "Workout Mix",
        "High tempo & energy, measured from the audio",
        measured_mix(seeds, |features| {
            features.tempo_bpm >= WORKOUT_MIN_TEMPO_BPM
                && features.energy_mean >= WORKOUT_MIN_ENERGY
        }),
    );
    push(
        playlists,
        seeds,
        PlaylistKind::ForYou,
        "wind-down-measured",
        "Wind Down",
        "Low tempo & energy, measured from the audio",
        measured_mix(seeds, |features| {
            features.tempo_bpm <= CHILL_MAX_TEMPO_BPM
                && features.energy_mean <= CHILL_MAX_ENERGY
                && features.brightness <= CHILL_MAX_BRIGHTNESS
        }),
    );
}

fn measured_mix(
    seeds: &PlaylistSeeds,
    matches: impl Fn(&aro_track_id::audio_features::AudioFeatures) -> bool,
) -> Vec<String> {
    let mut candidates: Vec<(&str, f64)> = seeds
        .tracks
        .iter()
        .filter_map(|track| {
            let features = decoded_features(track)?;
            if !matches(&features) {
                return None;
            }
            Some((track.content_hash.as_str(), features.tempo_bpm))
        })
        .collect();
    candidates.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(b.0)));
    candidates
        .into_iter()
        .map(|(hash, _)| hash.to_string())
        .collect()
}

/// Tier 3: k-means clustering over each analyzed track's full similarity vector (see
/// `AudioFeatures::vector` — tempo/energy/brightness/dynamic-range/danceability plus
/// MFCC and chroma), producing Spotify-style "Daily Mix" clusters — groups of
/// audio-similar tracks, distinct from the tag/behaviour-driven playlists above.
/// Skipped entirely when fewer than [`DAILY_MIX_MIN_TRACKS`] tracks have been
/// analyzed. Clusters are numbered by descending average decayed affinity, so
/// "Daily Mix 1" is built from the listener's most-played cluster.
fn push_daily_mixes(playlists: &mut Vec<GeneratedPlaylist>, seeds: &PlaylistSeeds, seed: u64) {
    let entries: Vec<(&str, Vec<f64>)> = seeds
        .tracks
        .iter()
        .filter_map(|track| {
            let features = decoded_features(track)?;
            Some((track.content_hash.as_str(), features.vector()))
        })
        .collect();
    if entries.len() < DAILY_MIX_MIN_TRACKS {
        return;
    }

    let vectors: Vec<&[f64]> = entries
        .iter()
        .map(|(_, vector)| vector.as_slice())
        .collect();
    let assignments = kmeans(&vectors, DAILY_MIX_COUNT, seed);

    let mut clusters: Vec<Vec<&str>> = vec![Vec::new(); DAILY_MIX_COUNT];
    for (index, cluster) in assignments.iter().enumerate() {
        clusters[*cluster].push(entries[index].0);
    }

    let mut ranked_clusters: Vec<&Vec<&str>> = clusters.iter().collect();
    ranked_clusters.sort_by(|a, b| {
        let affinity = |cluster: &Vec<&str>| -> f64 {
            cluster
                .iter()
                .map(|hash| {
                    seeds
                        .listening
                        .get(*hash)
                        .map(|s| s.decayed_affinity)
                        .unwrap_or(0.0)
                })
                .sum()
        };
        affinity(b).total_cmp(&affinity(a))
    });

    for (index, cluster) in ranked_clusters.into_iter().enumerate() {
        let hashes = order_by_affinity(
            seeds,
            &cluster
                .iter()
                .map(|hash| hash.to_string())
                .collect::<Vec<_>>(),
        );
        push(
            playlists,
            seeds,
            PlaylistKind::ForYou,
            &format!("daily-mix-{}", index + 1),
            &format!("Daily Mix {}", index + 1),
            "Grouped by how your music actually sounds",
            hashes,
        );
    }
}

/// Deterministic k-means (Lloyd's algorithm): assigns each of `vectors` to one of
/// `k` clusters, returning the cluster index per input vector in the same order.
/// Centroids are seeded from evenly-spaced vectors (not randomly) so results are
/// reproducible for a given `seed` — `push_daily_mixes` passes the same daily seed
/// every other daily-rotating playlist uses, so cluster boundaries shift gently day
/// to day rather than reshuffling on every request.
fn kmeans(vectors: &[&[f64]], k: usize, seed: u64) -> Vec<usize> {
    if vectors.is_empty() || k == 0 {
        return Vec::new();
    }
    let dims = vectors[0].len();
    let k = k.min(vectors.len());

    // Evenly-spaced starting points, offset by `seed` so the exact split rotates —
    // avoids every run picking identical starting indices, which can bias Lloyd's
    // algorithm toward the same local optimum every time.
    let offset = (seed as usize) % vectors.len();
    let mut centroids: Vec<Vec<f64>> = (0..k)
        .map(|i| vectors[(offset + i * vectors.len() / k) % vectors.len()].to_vec())
        .collect();

    let mut assignments = vec![0_usize; vectors.len()];
    for _ in 0..KMEANS_ITERATIONS {
        let mut changed = false;
        for (index, vector) in vectors.iter().enumerate() {
            let mut best_cluster = 0;
            let mut best_distance = f64::MAX;
            for (cluster, centroid) in centroids.iter().enumerate() {
                let distance = squared_distance(vector, centroid);
                if distance < best_distance {
                    best_distance = distance;
                    best_cluster = cluster;
                }
            }
            if assignments[index] != best_cluster {
                changed = true;
            }
            assignments[index] = best_cluster;
        }

        let mut sums = vec![vec![0.0_f64; dims]; k];
        let mut counts = vec![0_usize; k];
        for (index, vector) in vectors.iter().enumerate() {
            let cluster = assignments[index];
            counts[cluster] += 1;
            for (dim, value) in vector.iter().enumerate() {
                sums[cluster][dim] += value;
            }
        }
        for cluster in 0..k {
            if counts[cluster] == 0 {
                continue;
            }
            for dim in 0..dims {
                centroids[cluster][dim] = sums[cluster][dim] / counts[cluster] as f64;
            }
        }

        if !changed {
            break;
        }
    }
    assignments
}

fn squared_distance(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b.iter()).map(|(x, y)| (x - y).powi(2)).sum()
}

/// Orders `content_hashes` so consecutive tracks sound alike — a greedy
/// nearest-neighbour walk through the measured feature space, starting from
/// `start_hash` (or the first analyzed track when that isn't given or isn't
/// analyzed).
///
/// This is what separates "smart" shuffle from `shuffled()`: a uniform shuffle is
/// *correct* but jarring, dropping a ballad between two thrash tracks purely by
/// chance. Walking to the nearest unvisited neighbour each step keeps timbre, tempo
/// and energy drifting gradually instead, so the queue flows.
///
/// Deliberately greedy rather than an optimal path: this is a nearest-neighbour
/// heuristic for the open travelling-salesman problem, which is NP-hard, and the
/// difference is imperceptible for something whose only job is to avoid jarring
/// transitions. Cost stays O(n²) over a queue, which is trivial at library sizes.
///
/// Tracks with no analysis yet can't be placed meaningfully, so they keep their
/// original relative order and are appended at the end rather than dropped — a
/// shuffle that silently loses tracks would be a far worse bug than one that
/// sequences a few imperfectly.
pub fn smart_shuffle(
    seeds: &PlaylistSeeds,
    content_hashes: &[String],
    start_hash: Option<&str>,
) -> Vec<String> {
    let requested: std::collections::HashSet<&str> =
        content_hashes.iter().map(String::as_str).collect();

    let mut vectors: std::collections::HashMap<&str, Vec<f64>> = std::collections::HashMap::new();
    for track in &seeds.tracks {
        if requested.contains(track.content_hash.as_str())
            && let Some(features) = decoded_features(track)
        {
            vectors.insert(track.content_hash.as_str(), features.vector());
        }
    }

    // Preserves the caller's ordering for anything we can't place.
    let unanalyzed: Vec<String> = content_hashes
        .iter()
        .filter(|hash| !vectors.contains_key(hash.as_str()))
        .cloned()
        .collect();

    let mut remaining: Vec<&str> = content_hashes
        .iter()
        .map(String::as_str)
        .filter(|hash| vectors.contains_key(hash))
        .collect();
    if remaining.is_empty() {
        return unanalyzed;
    }

    // Honour the requested starting track so the caller's chosen song stays first
    // (the listener picked it); otherwise begin wherever the list does.
    let start_index = start_hash
        .and_then(|hash| remaining.iter().position(|candidate| *candidate == hash))
        .unwrap_or(0);
    let mut ordered = Vec::with_capacity(remaining.len() + unanalyzed.len());
    let mut current = remaining.swap_remove(start_index);
    ordered.push(current.to_string());

    while !remaining.is_empty() {
        let current_vector = &vectors[current];
        let (nearest_index, _) = remaining
            .iter()
            .enumerate()
            .map(|(index, hash)| (index, squared_distance(current_vector, &vectors[hash])))
            // `total_cmp` rather than `partial_cmp`: distances are finite here, but
            // this keeps the ordering total regardless, and ties break on the
            // earlier index so the walk stays deterministic for a given input.
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .expect("remaining is non-empty");
        current = remaining.swap_remove(nearest_index);
        ordered.push(current.to_string());
    }

    ordered.extend(unanalyzed);
    ordered
}

/// Tier 3: "seed-track radio" — the tracks most similar to `seed_hash` by audio
/// feature vector, nearest first, with `seed_hash` itself in front so the result is
/// immediately playable as a coherent queue. Excludes tracks with a high skip rate
/// (see [`RADIO_MAX_SKIP_RATE`]) — timbrally similar isn't a good suggestion if the
/// listener has actively rejected it before. Returns `None` if the seed hasn't been
/// analyzed yet, or no other analyzed tracks exist to recommend.
pub fn radio(seeds: &PlaylistSeeds, seed_hash: &str, limit: usize) -> Option<GeneratedPlaylist> {
    let seed_track = seeds
        .tracks
        .iter()
        .find(|track| track.content_hash == seed_hash)?;
    let seed_features = decoded_features(seed_track)?;
    let seed_vector = seed_features.vector();

    let mut ranked: Vec<(&str, f64)> = seeds
        .tracks
        .iter()
        .filter(|track| track.content_hash != seed_hash)
        .filter_map(|track| {
            let summary = seeds.listening.get(&track.content_hash);
            if let Some(summary) = summary
                && summary.play_count > 0
                && summary.skip_count as f64 / summary.play_count as f64 > RADIO_MAX_SKIP_RATE
            {
                return None;
            }
            let features = decoded_features(track)?;
            Some((
                track.content_hash.as_str(),
                squared_distance(&seed_vector, &features.vector()),
            ))
        })
        .collect();
    if ranked.is_empty() {
        return None;
    }
    ranked.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(b.0)));
    ranked.truncate(limit.max(1));

    let mut content_hashes = vec![seed_hash.to_string()];
    content_hashes.extend(ranked.into_iter().map(|(hash, _)| hash.to_string()));

    Some(GeneratedPlaylist {
        id: format!("radio-{seed_hash}"),
        title: "Radio".to_string(),
        subtitle: "Similar to what's playing, measured from the audio".to_string(),
        content_hashes,
        kind: PlaylistKind::ForYou,
        last_played_at: seeds.listening.get(seed_hash).map(|s| s.last_played_at),
    })
}

/// Content hashes ordered by descending decayed affinity (unplayed hashes sort last, at
/// 0.0), tie-broken by hash for stability.
fn order_by_affinity(seeds: &PlaylistSeeds, hashes: &[String]) -> Vec<String> {
    let mut ranked: Vec<(&String, f64)> = hashes
        .iter()
        .map(|hash| {
            (
                hash,
                seeds
                    .listening
                    .get(hash)
                    .map(|s| s.decayed_affinity)
                    .unwrap_or(0.0),
            )
        })
        .collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    ranked.into_iter().map(|(hash, _)| hash.clone()).collect()
}

/// Lowercase, ASCII-alphanumeric slug for use in playlist ids — collapses runs of
/// anything else (spaces, punctuation, unicode) into a single `-`.
fn slugify(text: &str) -> String {
    let mut slug = String::with_capacity(text.len());
    let mut last_was_dash = true; // avoids a leading '-'
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            last_was_dash = false;
        } else if !last_was_dash {
            slug.push('-');
            last_was_dash = true;
        }
    }
    slug.trim_end_matches('-').to_string()
}

/// Content hashes with a listening summary, ordered by descending `metric`, ties broken
/// by hash so equal-metric ordering is stable across calls.
fn ranked_by(seeds: &PlaylistSeeds, metric: impl Fn(&ListeningEventSummary) -> f64) -> Vec<String> {
    let mut ranked: Vec<(&String, f64)> = seeds
        .listening
        .iter()
        .map(|(hash, summary)| (hash, metric(summary)))
        .collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    ranked.into_iter().map(|(hash, _)| hash.clone()).collect()
}

/// Historically well-played tracks that have gone quiet. "Well played" is the listener's
/// own top quartile (see [`ListeningScale`]), not a fixed count, so this stays a short,
/// meaningful shelf whether their history runs to dozens of plays or millions. Ordered by
/// lifetime play count descending, so the tracks with the strongest history lead.
fn forgotten_favourites(seeds: &PlaylistSeeds, now: DateTime<Utc>) -> Vec<String> {
    let scale = ListeningScale::from_seeds(seeds);
    let well_played = scale.well_played();
    let now_secs = now.timestamp() as f64;
    let mut candidates: Vec<(&String, i64)> = seeds
        .listening
        .iter()
        .filter(|(_, summary)| {
            summary.play_count >= well_played
                && (now_secs - summary.last_played_at) / 86_400.0 >= FORGOTTEN_MIN_DAYS_SINCE_PLAY
        })
        .map(|(hash, summary)| (hash, summary.play_count))
        .collect();
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    candidates
        .into_iter()
        .map(|(hash, _)| hash.clone())
        .collect()
}

/// Recently added tracks that haven't been given a fair listen yet — see
/// [`FRESH_MAX_DAYS`]/[`FRESH_MAX_PLAYS`]. Ordered newest-first.
fn fresh_finds(seeds: &PlaylistSeeds, now: DateTime<Utc>) -> Vec<String> {
    let now_millis = now.timestamp_millis();
    let mut candidates: Vec<(&str, i64)> = seeds
        .tracks
        .iter()
        .filter_map(|track| {
            let first_seen = track.first_seen_at_millis?;
            let age_days = (now_millis - first_seen) / 86_400_000;
            if age_days > FRESH_MAX_DAYS {
                return None;
            }
            let play_count = seeds
                .listening
                .get(&track.content_hash)
                .map(|summary| summary.play_count)
                .unwrap_or(0);
            if play_count > FRESH_MAX_PLAYS {
                return None;
            }
            Some((track.content_hash.as_str(), first_seen))
        })
        .collect();
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    candidates
        .into_iter()
        .map(|(hash, _)| hash.to_string())
        .collect()
}

/// Tracks whose plays skew heavily into one local-time window (morning, late night, …)
/// for the *requesting device's* timezone. The play-count gate is the listener's own
/// median (see [`ListeningScale`]) rather than a fixed count, so a heavy listener isn't
/// swamped by tracks they played twice. `hour_histogram` is recorded in UTC; `utc_offset_minutes`
/// shifts it to local hours before matching against `local_hours`.
fn time_of_day(seeds: &PlaylistSeeds, local_hours: &[u32], utc_offset_minutes: i32) -> Vec<String> {
    let offset_hours = utc_offset_minutes.div_euclid(60);
    let representative = ListeningScale::from_seeds(seeds).representative();
    let mut candidates: Vec<(&String, f64)> = Vec::new();
    for (hash, summary) in &seeds.listening {
        if summary.play_count < representative {
            continue;
        }
        let matching: i64 = summary
            .hour_histogram
            .iter()
            .enumerate()
            .filter(|(utc_hour, _)| {
                let local_hour = (*utc_hour as i32 + offset_hours).rem_euclid(24) as u32;
                local_hours.contains(&local_hour)
            })
            .map(|(_, count)| *count)
            .sum();
        let fraction = matching as f64 / summary.play_count as f64;
        if fraction >= TIME_OF_DAY_MIN_FRACTION {
            candidates.push((hash, fraction));
        }
    }
    candidates.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    candidates
        .into_iter()
        .map(|(hash, _)| hash.clone())
        .collect()
}

fn push(
    playlists: &mut Vec<GeneratedPlaylist>,
    seeds: &PlaylistSeeds,
    kind: PlaylistKind,
    id: &str,
    title: &str,
    subtitle: &str,
    mut content_hashes: Vec<String>,
) {
    if content_hashes.len() < MINIMUM_TRACK_COUNT {
        return;
    }
    content_hashes.truncate(MAXIMUM_TRACK_COUNT);
    let last_played_at = content_hashes
        .iter()
        .filter_map(|hash| {
            seeds
                .listening
                .get(hash)
                .map(|summary| summary.last_played_at)
        })
        .fold(None, |max, value| {
            Some(max.map_or(value, |max: f64| max.max(value)))
        });
    playlists.push(GeneratedPlaylist {
        id: id.to_string(),
        title: title.to_string(),
        subtitle: subtitle.to_string(),
        content_hashes,
        kind,
        last_played_at,
    });
}

/// Picks a title/subtitle for one mood group. `relaxed` gets a weekend-aware variant;
/// the others stay constant. Subtitles credit MusicBrainz honestly, since that's where
/// the mood signal genuinely comes from.
fn mood_presentation(mood: &str, now: DateTime<Utc>) -> (&'static str, &'static str) {
    match mood {
        "relaxed" => {
            let weekend = matches!(now.weekday(), Weekday::Sat | Weekday::Sun);
            (
                if weekend {
                    "Sunday Slowdown"
                } else {
                    "Chill Out"
                },
                "Mellow & relaxed, tagged via MusicBrainz",
            )
        }
        "energetic" => ("Turn It Up", "High energy, tagged via MusicBrainz"),
        "feelgood" => ("Feel Good Mix", "Upbeat & sunny, tagged via MusicBrainz"),
        "mellow" => ("Quiet Hours", "Melancholy & moody, tagged via MusicBrainz"),
        _ => ("Mix", "Tagged via MusicBrainz"),
    }
}

/// A stable integer for `now`'s calendar day — the same value all day, different the
/// next, so the daily-seeded shuffle persists through the day and rotates day to day
/// without persisting any shuffled order.
fn daily_seed(now: DateTime<Utc>) -> u64 {
    (now.year() as u64).wrapping_mul(1_000) + now.ordinal() as u64
}

/// Deterministic Fisher–Yates over a SplitMix64 stream, so a given seed always shuffles
/// the same way — `rand::thread_rng` is intentionally non-reproducible and would make
/// the playlist reshuffle on every request.
fn shuffle(values: &mut [String], seed: u64) {
    let mut state = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut next = move || {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    };
    for index in (1..values.len()).rev() {
        let swap_with = (next() % (index as u64 + 1)) as usize;
        values.swap(index, swap_with);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aro_sync_store::PlaylistSeedTrack;
    use chrono::TimeZone;
    use std::collections::HashMap;

    fn track(hash: &str, favourite: bool, moods: &[&str]) -> PlaylistSeedTrack {
        PlaylistSeedTrack {
            content_hash: hash.to_string(),
            favourite,
            mood_tags: moods.iter().map(|mood| mood.to_string()).collect(),
            first_seen_at_millis: None,
            artist: None,
            album: None,
            release_year: None,
            audio_features_json: None,
        }
    }

    fn wednesday() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2025, 12, 3, 12, 0, 0).unwrap()
    }

    fn sunday() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2025, 11, 30, 12, 0, 0).unwrap()
    }

    fn generate_utc(seeds: &PlaylistSeeds, now: DateTime<Utc>) -> Vec<GeneratedPlaylist> {
        generate(seeds, now, 0)
    }

    fn summary(
        play_count: i64,
        last_played_at: f64,
        decayed_affinity: f64,
    ) -> ListeningEventSummary {
        ListeningEventSummary {
            play_count,
            skip_count: 0,
            completed_count: play_count,
            last_played_at,
            decayed_affinity,
            hour_histogram: [0; 24],
            current_month_play_count: 0,
            first_played_year: None,
            last_played_year: None,
        }
    }

    /// The point of a relative threshold is that it means the same thing at any scale.
    /// A fixed "at least three plays" picks out a handful of tracks for a light listener
    /// and nearly the whole library for a heavy one, so the shelf quietly stops
    /// discriminating exactly when there is most to discriminate between.
    #[test]
    fn well_played_tracks_the_listeners_own_distribution() {
        // A short history: the floor governs, because a percentile of a few plays is noise.
        let light = PlaylistSeeds {
            listening: HashMap::from([
                ("a".to_string(), summary(1, 0.0, 0.0)),
                ("b".to_string(), summary(1, 0.0, 0.0)),
                ("c".to_string(), summary(2, 0.0, 0.0)),
            ]),
            ..Default::default()
        };
        assert_eq!(
            ListeningScale::from_seeds(&light).well_played(),
            FORGOTTEN_MIN_PLAYS_FLOOR,
            "a short history should fall back to the floor"
        );

        // A heavy history: three plays is now unremarkable, and the threshold rises with
        // the distribution instead of admitting almost everything.
        let heavy = PlaylistSeeds {
            listening: (0..100)
                .map(|index| {
                    (
                        format!("track-{index}"),
                        summary(index as i64 + 1, 0.0, 0.0),
                    )
                })
                .collect(),
            ..Default::default()
        };
        let threshold = ListeningScale::from_seeds(&heavy).well_played();
        assert!(
            threshold >= 40,
            "expected roughly the median of 1..=100, got {threshold}"
        );

        // No history at all must not divide by zero or admit everything.
        let empty = PlaylistSeeds::default();
        assert_eq!(
            ListeningScale::from_seeds(&empty).well_played(),
            FORGOTTEN_MIN_PLAYS_FLOOR
        );
    }

    /// Guards the failure mode that makes an adaptive threshold worth having: at scale a
    /// fixed count admits nearly everything, and a shelf that matches everything is as
    /// useless as one that matches nothing.
    #[test]
    fn forgotten_favourites_stays_selective_on_a_large_history() {
        let now = Utc.with_ymd_and_hms(2026, 8, 5, 12, 0, 0).unwrap();
        let long_ago = now.timestamp() as f64 - 200.0 * 86_400.0;
        let seeds = PlaylistSeeds {
            listening: (0..200)
                .map(|index| {
                    (
                        format!("track-{index}"),
                        summary(index as i64 + 1, long_ago, 0.0),
                    )
                })
                .collect(),
            ..Default::default()
        };
        let forgotten = forgotten_favourites(&seeds, now);
        assert!(
            forgotten.len() <= 105,
            "a fixed floor of 3 plays would admit 198 of these 200 tracks; got {}",
            forgotten.len()
        );
        assert!(
            !forgotten.is_empty(),
            "the shelf should still find something"
        );
    }

    #[test]
    fn recently_loved_contains_only_favourites_and_needs_three() {
        let seeds = PlaylistSeeds {
            tracks: vec![
                track("a", true, &[]),
                track("b", true, &[]),
                track("c", true, &[]),
                track("d", false, &[]),
            ],
            ..Default::default()
        };

        let playlists = generate_utc(&seeds, wednesday());
        let loved = playlists.iter().find(|p| p.id == "recently-loved").unwrap();
        assert_eq!(loved.content_hashes, vec!["a", "b", "c"]);

        let two_favourites = PlaylistSeeds {
            tracks: vec![track("a", true, &[]), track("b", true, &[])],
            ..Default::default()
        };
        assert!(
            !generate_utc(&two_favourites, wednesday())
                .iter()
                .any(|p| p.id == "recently-loved")
        );
    }

    #[test]
    fn heavy_rotation_ranks_by_decayed_affinity_and_caps_at_thirty() {
        let mut listening = HashMap::new();
        for i in 0..40 {
            // Highest hash-0 affinity, descending — mirrors what a real decay
            // computation would produce for tracks played with varying recency.
            listening.insert(format!("hash-{i}"), summary(10, 1_000.0, 40.0 - i as f64));
        }
        let seeds = PlaylistSeeds {
            listening,
            ..Default::default()
        };

        let playlists = generate_utc(&seeds, wednesday());
        let rotation = playlists.iter().find(|p| p.id == "heavy-rotation").unwrap();
        assert_eq!(rotation.content_hashes.len(), 30);
        assert_eq!(rotation.content_hashes[0], "hash-0");
        assert_eq!(rotation.content_hashes[29], "hash-29");
    }

    #[test]
    fn mood_playlists_need_three_tagged_tracks_and_are_weekend_aware() {
        let seeds = PlaylistSeeds {
            tracks: vec![
                track("a", false, &["relaxed"]),
                track("b", false, &["relaxed"]),
                track("c", false, &["relaxed"]),
                track("d", false, &[]),
            ],
            ..Default::default()
        };

        let weekday = generate_utc(&seeds, wednesday());
        let weekend = generate_utc(&seeds, sunday());
        let weekday_mood = weekday.iter().find(|p| p.id == "mood-relaxed").unwrap();
        let weekend_mood = weekend.iter().find(|p| p.id == "mood-relaxed").unwrap();

        assert_eq!(weekday_mood.title, "Chill Out");
        assert_eq!(weekend_mood.title, "Sunday Slowdown");
        assert!(weekday_mood.subtitle.contains("MusicBrainz"));
        assert_eq!(weekday_mood.content_hashes.len(), 3);
        assert!(!weekday_mood.content_hashes.contains(&"d".to_string()));

        let sparse = PlaylistSeeds {
            tracks: vec![track("a", false, &["relaxed"])],
            ..Default::default()
        };
        assert!(
            !generate_utc(&sparse, wednesday())
                .iter()
                .any(|p| p.id.starts_with("mood-"))
        );
    }

    #[test]
    fn deep_cuts_excludes_played_and_shuffles_deterministically_per_day() {
        let mut listening = HashMap::new();
        for i in 0..4 {
            listening.insert(format!("hash-{i}"), summary(1, 1_000.0, 1.0));
        }
        let seeds = PlaylistSeeds {
            tracks: (0..10)
                .map(|i| track(&format!("hash-{i}"), false, &[]))
                .collect(),
            listening,
            ..Default::default()
        };

        let first = generate_utc(&seeds, wednesday());
        let second = generate_utc(&seeds, wednesday());
        let other_day = generate_utc(&seeds, sunday());

        let cuts = |playlists: &[GeneratedPlaylist]| {
            playlists
                .iter()
                .find(|p| p.id == "deep-cuts")
                .unwrap()
                .content_hashes
                .clone()
        };
        assert_eq!(cuts(&first), cuts(&second));
        assert_ne!(cuts(&first), cuts(&other_day));
        for played in seeds.listening.keys() {
            assert!(!cuts(&first).contains(played));
        }
        assert_eq!(cuts(&first).len(), 6);
    }

    #[test]
    fn forgotten_favourites_needs_history_and_ninety_days_of_silence() {
        let now = wednesday();
        let now_secs = now.timestamp() as f64;
        let mut listening = HashMap::new();
        // Well-played, silent for 120 days — a real forgotten favourite.
        for i in 0..3 {
            listening.insert(
                format!("forgotten-{i}"),
                summary(5, now_secs - 120.0 * 86_400.0, 0.01),
            );
        }
        // Well-played, but played yesterday — not forgotten.
        listening.insert("recent".into(), summary(10, now_secs - 86_400.0, 5.0));
        // Silent for 120 days, but only played once — not a "favourite" to forget.
        listening.insert(
            "one-hit".into(),
            summary(1, now_secs - 120.0 * 86_400.0, 0.01),
        );

        let seeds = PlaylistSeeds {
            listening,
            ..Default::default()
        };

        let playlists = generate(&seeds, now, 0);
        let forgotten = playlists
            .iter()
            .find(|p| p.id == "forgotten-favourites")
            .unwrap();
        assert_eq!(
            forgotten.content_hashes.len(),
            3,
            "{:?}",
            forgotten.content_hashes
        );
        assert!(
            forgotten
                .content_hashes
                .iter()
                .all(|h| h.starts_with("forgotten-"))
        );
    }

    #[test]
    fn fresh_finds_needs_recent_addition_and_at_most_one_play() {
        let now = wednesday();
        let now_millis = now.timestamp_millis();
        let mut tracks = Vec::new();
        for i in 0..3 {
            let mut t = track(&format!("fresh-{i}"), false, &[]);
            t.first_seen_at_millis = Some(now_millis - 5 * 86_400_000);
            tracks.push(t);
        }
        // Added long ago — not fresh.
        let mut old = track("old", false, &[]);
        old.first_seen_at_millis = Some(now_millis - 400 * 86_400_000);
        tracks.push(old);
        // Added recently, but already played twice — not "barely played".
        let mut overplayed = track("overplayed", false, &[]);
        overplayed.first_seen_at_millis = Some(now_millis - 5 * 86_400_000);
        tracks.push(overplayed);

        let mut listening = HashMap::new();
        listening.insert("overplayed".to_string(), summary(2, 0.0, 0.0));

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };

        let playlists = generate(&seeds, now, 0);
        let fresh = playlists.iter().find(|p| p.id == "fresh-finds").unwrap();
        assert_eq!(fresh.content_hashes.len(), 3, "{:?}", fresh.content_hashes);
        assert!(fresh.content_hashes.iter().all(|h| h.starts_with("fresh-")));
    }

    #[test]
    fn time_of_day_playlists_respect_the_requesters_utc_offset() {
        // Three tracks played almost entirely at UTC hour 7 (2am US Eastern in winter,
        // UTC-5 — late night for that listener; 7am UK winter, UTC+0 — morning there).
        let mut listening = HashMap::new();
        for i in 0..3 {
            let mut histogram = [0_i64; 24];
            histogram[7] = 9;
            histogram[8] = 1;
            listening.insert(
                format!("night-owl-{i}"),
                ListeningEventSummary {
                    play_count: 10,
                    skip_count: 0,
                    completed_count: 10,
                    last_played_at: 0.0,
                    decayed_affinity: 1.0,
                    hour_histogram: histogram,
                    current_month_play_count: 0,
                    first_played_year: None,
                    last_played_year: None,
                },
            );
        }
        let seeds = PlaylistSeeds {
            listening,
            ..Default::default()
        };

        let uk = generate(&seeds, wednesday(), 0);
        let us_eastern = generate(&seeds, wednesday(), -5 * 60);

        assert!(uk.iter().any(|p| p.id == "morning-rotation"));
        assert!(!uk.iter().any(|p| p.id == "late-night"));
        assert!(us_eastern.iter().any(|p| p.id == "late-night"));
        assert!(!us_eastern.iter().any(|p| p.id == "morning-rotation"));
    }

    fn track_full(
        hash: &str,
        artist: Option<&str>,
        album: Option<&str>,
        release_year: Option<i64>,
    ) -> PlaylistSeedTrack {
        PlaylistSeedTrack {
            content_hash: hash.to_string(),
            favourite: false,
            mood_tags: Vec::new(),
            first_seen_at_millis: None,
            artist: artist.map(str::to_string),
            album: album.map(str::to_string),
            release_year,
            audio_features_json: None,
        }
    }

    #[test]
    fn artist_mix_ranks_by_recent_affinity_and_favourite_artists_by_lifetime_plays() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        // Alpha: high recent affinity, few lifetime plays.
        for i in 0..3 {
            let hash = format!("alpha-{i}");
            tracks.push(track_full(&hash, Some("Alpha"), None, None));
            listening.insert(hash, summary(1, 100.0, 10.0));
        }
        // Beta: low recent affinity, many lifetime plays.
        for i in 0..3 {
            let hash = format!("beta-{i}");
            tracks.push(track_full(&hash, Some("Beta"), None, None));
            listening.insert(hash, summary(5, 100.0, 1.0));
        }
        // Gamma: in the library, never played — shouldn't appear in either section.
        for i in 0..3 {
            tracks.push(track_full(&format!("gamma-{i}"), Some("Gamma"), None, None));
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let artist_mixes: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::ArtistMix)
            .collect();
        assert_eq!(artist_mixes.len(), 2);
        assert_eq!(artist_mixes[0].title, "More From Alpha");
        assert_eq!(artist_mixes[1].title, "More From Beta");

        let favourite_artists: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::FavouriteArtist)
            .collect();
        assert_eq!(favourite_artists.len(), 2);
        assert_eq!(favourite_artists[0].title, "Beta");
        assert_eq!(favourite_artists[1].title, "Alpha");
    }

    #[test]
    fn artist_mix_prefers_multi_album_artists_over_single_album_despite_lower_affinity() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        // Solo: single album, high affinity.
        for i in 0..3 {
            let hash = format!("solo-{i}");
            tracks.push(track_full(&hash, Some("Solo"), Some("Solo Album"), None));
            listening.insert(hash, summary(1, 100.0, 10.0));
        }
        // Multi: two distinct albums, lower affinity.
        for i in 0..3 {
            let hash = format!("multi-{i}");
            let album = if i == 0 {
                "Multi Album A"
            } else {
                "Multi Album B"
            };
            tracks.push(track_full(&hash, Some("Multi"), Some(album), None));
            listening.insert(hash, summary(1, 100.0, 5.0));
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let artist_mixes: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::ArtistMix)
            .collect();
        assert_eq!(artist_mixes.len(), 2);
        assert_eq!(artist_mixes[0].title, "More From Multi");
        assert_eq!(artist_mixes[1].title, "More From Solo");
    }

    #[test]
    fn recently_played_albums_group_by_album_and_rank_by_most_recent_play() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        for i in 0..3 {
            let hash = format!("old-{i}");
            tracks.push(track_full(&hash, Some("Artist"), Some("Album Two"), None));
            listening.insert(hash, summary(1, 1_000.0, 1.0));
        }
        for i in 0..3 {
            let hash = format!("new-{i}");
            tracks.push(track_full(&hash, Some("Artist"), Some("Album One"), None));
            listening.insert(hash, summary(1, 2_000.0, 1.0));
        }
        // Too few tracks to form a playlist — dropped by the minimum-track-count cutoff.
        for i in 0..2 {
            let hash = format!("solo-{i}");
            tracks.push(track_full(&hash, Some("Artist"), Some("Solo"), None));
            listening.insert(hash, summary(1, 3_000.0, 1.0));
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let albums: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::RecentlyPlayedAlbum)
            .collect();
        assert_eq!(albums.len(), 2);
        assert_eq!(albums[0].title, "Album One");
        assert_eq!(albums[1].title, "Album Two");
        assert!(!playlists.iter().any(|p| p.title == "Solo"));
    }

    #[test]
    fn lost_albums_surfaces_never_played_and_long_dormant_albums_but_not_recently_played_ones() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        let now = wednesday();
        let now_secs = now.timestamp() as f64;

        for i in 0..3 {
            let hash = format!("recent-{i}");
            tracks.push(track_full(
                &hash,
                Some("Artist"),
                Some("Recent Album"),
                None,
            ));
            listening.insert(hash, summary(5, now_secs - 5.0 * 86_400.0, 1.0));
        }
        for i in 0..3 {
            let hash = format!("dormant-{i}");
            tracks.push(track_full(
                &hash,
                Some("Artist"),
                Some("Dormant Album"),
                None,
            ));
            listening.insert(hash, summary(5, now_secs - 200.0 * 86_400.0, 0.01));
        }
        for i in 0..3 {
            // Never played at all — no listening entry.
            tracks.push(track_full(
                &format!("never-{i}"),
                Some("Artist"),
                Some("Never Played Album"),
                None,
            ));
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate(&seeds, now, 0);

        let lost: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::LostAlbum)
            .collect();
        assert_eq!(lost.len(), 2);
        // Never-played ranks ahead of long-dormant — the most "lost" first.
        assert_eq!(lost[0].title, "Never Played Album");
        assert_eq!(lost[1].title, "Dormant Album");
        assert!(
            !playlists
                .iter()
                .any(|p| { p.kind == PlaylistKind::LostAlbum && p.title == "Recent Album" })
        );
    }

    #[test]
    fn time_capsule_includes_loved_but_dormant_tracks_and_excludes_hot_or_underplayed_ones() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        let now = wednesday(); // year 2025

        for i in 0..3 {
            let hash = format!("loved-long-ago-{i}");
            tracks.push(track_full(&hash, None, None, None));
            listening.insert(
                hash,
                ListeningEventSummary {
                    last_played_year: Some(2022),
                    first_played_year: Some(2020),
                    ..summary(10, 0.0, 0.0)
                },
            );
        }
        for i in 0..3 {
            let hash = format!("hot-now-{i}");
            tracks.push(track_full(&hash, None, None, None));
            listening.insert(
                hash,
                ListeningEventSummary {
                    last_played_year: Some(2025),
                    first_played_year: Some(2025),
                    ..summary(20, 0.0, 0.0)
                },
            );
        }
        for i in 0..3 {
            let hash = format!("barely-played-long-ago-{i}");
            tracks.push(track_full(&hash, None, None, None));
            listening.insert(
                hash,
                ListeningEventSummary {
                    last_played_year: Some(2021),
                    first_played_year: Some(2021),
                    ..summary(1, 0.0, 0.0)
                },
            );
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate(&seeds, now, 0);

        let capsule = playlists
            .iter()
            .find(|p| p.kind == PlaylistKind::TimeCapsule)
            .expect("time capsule should be generated");
        for i in 0..3 {
            assert!(
                capsule
                    .content_hashes
                    .contains(&format!("loved-long-ago-{i}"))
            );
            assert!(!capsule.content_hashes.contains(&format!("hot-now-{i}")));
            assert!(
                !capsule
                    .content_hashes
                    .contains(&format!("barely-played-long-ago-{i}"))
            );
        }
    }

    #[test]
    fn hits_by_year_keeps_only_the_top_three_years_ranked_by_play_count() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        for (year, affinity) in [(2019, 1.0), (2020, 4.0), (2021, 3.0), (2022, 2.0)] {
            for i in 0..3 {
                let hash = format!("y{year}-{i}");
                tracks.push(track_full(&hash, None, None, Some(year)));
                // Track 0 in each year is played most, to check within-year ordering.
                let play_count = 3 - i;
                listening.insert(hash, summary(play_count, 1.0, affinity));
            }
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let hits: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::HitsByYear)
            .collect();
        assert_eq!(hits.len(), 3);
        // 2019 (lowest aggregate affinity) is dropped; 2020, 2021, 2022 survive in that order.
        assert_eq!(hits[0].title, "Hits of 2020");
        assert_eq!(hits[1].title, "Hits of 2021");
        assert_eq!(hits[2].title, "Hits of 2022");
        assert_eq!(hits[0].content_hashes[0], "y2020-0");
    }

    #[test]
    fn hits_by_year_prefers_multi_artist_years_over_single_artist_despite_lower_affinity() {
        let mut tracks = Vec::new();
        let mut listening = HashMap::new();
        // 2020: single artist, high affinity.
        for i in 0..3 {
            let hash = format!("y2020-{i}");
            tracks.push(track_full(&hash, Some("SoloArtist"), None, Some(2020)));
            listening.insert(hash, summary(1, 1.0, 10.0));
        }
        // 2021: two distinct artists, lower affinity.
        for i in 0..3 {
            let hash = format!("y2021-{i}");
            let artist = if i == 0 { "ArtistA" } else { "ArtistB" };
            tracks.push(track_full(&hash, Some(artist), None, Some(2021)));
            listening.insert(hash, summary(1, 1.0, 5.0));
        }

        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let hits: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.kind == PlaylistKind::HitsByYear)
            .collect();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].title, "Hits of 2021");
        assert_eq!(hits[1].title, "Hits of 2020");
    }

    #[test]
    fn replay_month_only_counts_this_months_plays_while_replay_all_time_uses_lifetime_plays() {
        let mut listening = HashMap::new();
        for i in 0..3 {
            listening.insert(
                format!("this-month-{i}"),
                ListeningEventSummary {
                    play_count: 2,
                    skip_count: 0,
                    completed_count: 2,
                    last_played_at: 0.0,
                    decayed_affinity: 1.0,
                    hour_histogram: [0; 24],
                    current_month_play_count: 2,
                    first_played_year: None,
                    last_played_year: None,
                },
            );
        }
        for i in 0..3 {
            // Heavily played historically, but not this month.
            listening.insert(format!("old-favourite-{i}"), summary(10, 0.0, 0.5));
        }

        let seeds = PlaylistSeeds {
            listening,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let month = playlists.iter().find(|p| p.id == "replay-month").unwrap();
        assert!(month.title.contains("Replay"));
        assert_eq!(month.content_hashes.len(), 3);
        assert!(
            month
                .content_hashes
                .iter()
                .all(|h| h.starts_with("this-month-"))
        );

        let all_time = playlists
            .iter()
            .find(|p| p.id == "replay-all-time")
            .unwrap();
        assert_eq!(all_time.content_hashes.len(), 6);
        assert!(all_time.content_hashes[0].starts_with("old-favourite-"));
    }

    fn features(
        tempo_bpm: f64,
        energy_mean: f64,
        brightness: f64,
        vector_seed: f64,
    ) -> aro_track_id::audio_features::AudioFeatures {
        aro_track_id::audio_features::AudioFeatures {
            tempo_bpm,
            energy_mean,
            energy_variance: 0.0,
            brightness,
            dynamic_range: 10.0,
            danceability: 0.5,
            mfcc: (0..26).map(|i| vector_seed + i as f64 * 0.01).collect(),
            chroma: (0..12).map(|i| vector_seed + i as f64 * 0.01).collect(),
        }
    }

    fn track_with_features(
        hash: &str,
        features: &aro_track_id::audio_features::AudioFeatures,
    ) -> PlaylistSeedTrack {
        let mut seed_track = track(hash, false, &[]);
        seed_track.audio_features_json = Some(serde_json::to_string(features).unwrap());
        seed_track
    }

    #[test]
    fn measured_mixes_use_tempo_and_energy_thresholds_and_flow_by_tempo() {
        let tracks = vec![
            track_with_features("workout-slow", &features(122.0, 0.09, 0.5, 0.0)),
            track_with_features("workout-fast", &features(150.0, 0.12, 0.5, 1.0)),
            // Fast but too quiet — doesn't qualify as a workout track.
            track_with_features("fast-but-quiet", &features(140.0, 0.02, 0.5, 2.0)),
            track_with_features("chill-a", &features(80.0, 0.05, 0.2, 3.0)),
            track_with_features("chill-b", &features(70.0, 0.04, 0.1, 4.0)),
            track_with_features("chill-c", &features(90.0, 0.055, 0.3, 3.5)),
            // Slow and quiet, but too bright to read as "chill".
            track_with_features("slow-but-bright", &features(75.0, 0.03, 0.9, 5.0)),
        ];
        let seeds = PlaylistSeeds {
            tracks,
            ..Default::default()
        };

        let playlists = generate_utc(&seeds, wednesday());

        let workout = playlists.iter().find(|p| p.id == "workout-measured");
        assert!(
            workout.is_none(),
            "only 2 qualifying tracks (below MINIMUM_TRACK_COUNT) should drop the playlist"
        );

        // Add a third qualifying workout track so the minimum-count gate passes, and
        // verify ordering flows slowest-to-fastest.
        let mut tracks_with_third = seeds.tracks.clone();
        tracks_with_third.push(track_with_features(
            "workout-mid",
            &features(135.0, 0.1, 0.5, 6.0),
        ));
        let seeds = PlaylistSeeds {
            tracks: tracks_with_third,
            ..Default::default()
        };
        let playlists = generate_utc(&seeds, wednesday());

        let workout = playlists
            .iter()
            .find(|p| p.id == "workout-measured")
            .unwrap();
        assert_eq!(
            workout.content_hashes,
            vec!["workout-slow", "workout-mid", "workout-fast"]
        );
        assert!(
            !workout
                .content_hashes
                .contains(&"fast-but-quiet".to_string())
        );

        let wind_down = playlists
            .iter()
            .find(|p| p.id == "wind-down-measured")
            .unwrap();
        assert_eq!(
            wind_down.content_hashes,
            vec!["chill-b", "chill-a", "chill-c"]
        );
        assert!(
            !wind_down
                .content_hashes
                .contains(&"slow-but-bright".to_string())
        );
    }

    #[test]
    fn daily_mixes_need_a_minimum_of_analyzed_tracks_and_cluster_by_vector_similarity() {
        // Four well-separated groups (vector seeds far apart), 8 tracks each — right at
        // DAILY_MIX_MIN_TRACKS, so k-means has enough data and should recover exactly
        // these 4 groups.
        let mut tracks = Vec::new();
        for group in 0..4 {
            for i in 0..8 {
                let vector_seed = group as f64 * 100.0;
                tracks.push(track_with_features(
                    &format!("group{group}-track{i}"),
                    &features(120.0, 0.1, 0.5, vector_seed),
                ));
            }
        }
        let seeds = PlaylistSeeds {
            tracks: tracks.clone(),
            ..Default::default()
        };

        let playlists = generate_utc(&seeds, wednesday());
        let mixes: Vec<&GeneratedPlaylist> = playlists
            .iter()
            .filter(|p| p.id.starts_with("daily-mix-"))
            .collect();
        assert_eq!(
            mixes.len(),
            4,
            "{:?}",
            mixes.iter().map(|m| &m.id).collect::<Vec<_>>()
        );
        for mix in &mixes {
            assert_eq!(mix.content_hashes.len(), 8, "{:?}", mix.content_hashes);
            let group_prefix = &mix.content_hashes[0][..6];
            assert!(
                mix.content_hashes
                    .iter()
                    .all(|hash| hash.starts_with(group_prefix)),
                "cluster mixed groups: {:?}",
                mix.content_hashes
            );
        }

        // One track short of the minimum — no Daily Mixes at all.
        let mut sparse_tracks = tracks;
        sparse_tracks.pop();
        let sparse_seeds = PlaylistSeeds {
            tracks: sparse_tracks,
            ..Default::default()
        };
        let sparse_playlists = generate_utc(&sparse_seeds, wednesday());
        assert!(
            !sparse_playlists
                .iter()
                .any(|p| p.id.starts_with("daily-mix-"))
        );
    }

    #[test]
    fn smart_shuffle_walks_nearest_neighbours_and_parks_unanalyzed_tracks_at_the_end() {
        // Three clusters far apart in feature space, deliberately interleaved on
        // input so an unordered pass-through couldn't accidentally pass this.
        let calm_a = features(60.0, 0.01, 0.1, 0.0);
        let calm_b = features(62.0, 0.012, 0.11, 0.1);
        let mid = features(120.0, 0.05, 0.4, 20.0);
        let loud_a = features(180.0, 0.2, 0.9, 40.0);
        let loud_b = features(182.0, 0.21, 0.91, 40.5);

        let mut tracks = vec![
            track_with_features("calm-a", &calm_a),
            track_with_features("loud-a", &loud_a),
            track_with_features("mid", &mid),
            track_with_features("loud-b", &loud_b),
            track_with_features("calm-b", &calm_b),
        ];
        // No audio_features_json at all — can't be placed by similarity.
        tracks.push(track_full("unanalyzed", None, None, None));

        let seeds = PlaylistSeeds {
            tracks,
            ..Default::default()
        };
        let hashes: Vec<String> = ["calm-a", "loud-a", "mid", "loud-b", "calm-b", "unanalyzed"]
            .iter()
            .map(|hash| hash.to_string())
            .collect();

        let ordered = smart_shuffle(&seeds, &hashes, Some("calm-a"));

        // Nothing is lost, the requested start leads, and the unplaceable track is
        // parked at the end rather than dropped.
        assert_eq!(ordered.len(), hashes.len());
        assert_eq!(ordered[0], "calm-a");
        assert_eq!(ordered.last().unwrap(), "unanalyzed");

        // The walk should stay within a cluster before crossing to the next, so the
        // two calm tracks are adjacent and the two loud ones are adjacent.
        let position = |hash: &str| ordered.iter().position(|value| value == hash).unwrap();
        assert_eq!(
            position("calm-b"),
            1,
            "nearest neighbour of calm-a is calm-b"
        );
        assert!(
            position("loud-a").abs_diff(position("loud-b")) == 1,
            "loud tracks should end up adjacent, got {ordered:?}"
        );
        // ...and the midpoint should bridge the two clusters rather than sit inside one.
        assert_eq!(
            position("mid"),
            2,
            "mid should bridge calm -> loud, got {ordered:?}"
        );
    }

    #[test]
    fn radio_returns_seed_first_then_nearest_neighbours_and_excludes_heavy_skippers() {
        let seed_features = features(120.0, 0.1, 0.5, 0.0);
        let close_features = features(121.0, 0.1, 0.5, 0.01);
        let far_features = features(80.0, 0.02, 0.1, 50.0);
        let heavily_skipped_but_close = features(121.0, 0.1, 0.5, 0.02);

        let tracks = vec![
            track_with_features("seed", &seed_features),
            track_with_features("close", &close_features),
            track_with_features("far", &far_features),
            track_with_features("skipped-but-close", &heavily_skipped_but_close),
        ];
        let mut listening = HashMap::new();
        listening.insert(
            "skipped-but-close".to_string(),
            ListeningEventSummary {
                play_count: 10,
                skip_count: 9,
                completed_count: 1,
                last_played_at: 0.0,
                decayed_affinity: 0.0,
                hour_histogram: [0; 24],
                current_month_play_count: 0,
                first_played_year: None,
                last_played_year: None,
            },
        );
        let seeds = PlaylistSeeds {
            tracks,
            listening,
            ..Default::default()
        };

        let result = radio(&seeds, "seed", 10).unwrap();

        assert_eq!(result.content_hashes[0], "seed");
        assert!(result.content_hashes.contains(&"close".to_string()));
        assert!(result.content_hashes.contains(&"far".to_string()));
        assert!(
            !result
                .content_hashes
                .contains(&"skipped-but-close".to_string())
        );
        // "close" should rank ahead of "far" (nearer in vector space).
        let close_index = result
            .content_hashes
            .iter()
            .position(|h| h == "close")
            .unwrap();
        let far_index = result
            .content_hashes
            .iter()
            .position(|h| h == "far")
            .unwrap();
        assert!(close_index < far_index);

        assert!(radio(&seeds, "unknown-hash", 10).is_none());
    }
}
