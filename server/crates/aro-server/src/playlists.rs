//! Server-side auto-playlist generation — the hub derives playlists from its own
//! canonical analytics (synced `listening_events`, CRDT favourites, MusicBrainz mood
//! tags from background identification) and serves them to every client, keyed by
//! content hash. Clients only map hashes to their local catalogs and render; they never
//! generate. This keeps every device seeing the same playlists, and keeps the BI that
//! drives them on the hub, which is the durable, canonical copy of everything else too.

use aro_sync_store::PlaylistSeeds;
use chrono::{DateTime, Datelike, Utc, Weekday};
use serde::Serialize;

/// Playlists with fewer songs than this are dropped entirely — a "playlist" of 1-2
/// tracks reads as broken rather than useful.
const MINIMUM_TRACK_COUNT: usize = 3;
const MAXIMUM_TRACK_COUNT: usize = 30;

/// Mood tags recognized for playlist generation, in the fixed order they're considered —
/// must match the vocabulary `aro_track_id::musicbrainz::canonicalize_tags` can produce.
const MOOD_ORDER: [&str; 4] = ["relaxed", "energetic", "feelgood", "mellow"];

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
}

pub fn generate(seeds: &PlaylistSeeds, now: DateTime<Utc>) -> Vec<GeneratedPlaylist> {
    let seed = daily_seed(now);
    let mut playlists = Vec::new();

    push(
        &mut playlists,
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
        "heavy-rotation",
        "Heavy Rotation",
        "Most played",
        seeds.most_played.clone(),
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
        push(&mut playlists, &format!("mood-{mood}"), title, subtitle, hashes);
    }

    push(
        &mut playlists,
        "recently-played",
        "Recently Played",
        "Pick up where you left off",
        seeds.recently_played.clone(),
    );

    let mut deep_cuts: Vec<String> = seeds
        .tracks
        .iter()
        .filter(|track| !seeds.played.contains(&track.content_hash))
        .map(|track| track.content_hash.clone())
        .collect();
    shuffle(&mut deep_cuts, seed);
    push(
        &mut playlists,
        "deep-cuts",
        "Deep Cuts",
        "Rarely played",
        deep_cuts,
    );

    playlists
}

fn push(
    playlists: &mut Vec<GeneratedPlaylist>,
    id: &str,
    title: &str,
    subtitle: &str,
    mut content_hashes: Vec<String>,
) {
    if content_hashes.len() < MINIMUM_TRACK_COUNT {
        return;
    }
    content_hashes.truncate(MAXIMUM_TRACK_COUNT);
    playlists.push(GeneratedPlaylist {
        id: id.to_string(),
        title: title.to_string(),
        subtitle: subtitle.to_string(),
        content_hashes,
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
                if weekend { "Sunday Slowdown" } else { "Chill Out" },
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

    fn track(hash: &str, favourite: bool, moods: &[&str]) -> PlaylistSeedTrack {
        PlaylistSeedTrack {
            content_hash: hash.to_string(),
            favourite,
            mood_tags: moods.iter().map(|mood| mood.to_string()).collect(),
        }
    }

    fn wednesday() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2025, 12, 3, 12, 0, 0).unwrap()
    }

    fn sunday() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2025, 11, 30, 12, 0, 0).unwrap()
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

        let playlists = generate(&seeds, wednesday());
        let loved = playlists.iter().find(|p| p.id == "recently-loved").unwrap();
        assert_eq!(loved.content_hashes, vec!["a", "b", "c"]);

        let two_favourites = PlaylistSeeds {
            tracks: vec![track("a", true, &[]), track("b", true, &[])],
            ..Default::default()
        };
        assert!(
            !generate(&two_favourites, wednesday())
                .iter()
                .any(|p| p.id == "recently-loved")
        );
    }

    #[test]
    fn heavy_rotation_preserves_play_count_order_and_caps_at_thirty() {
        let seeds = PlaylistSeeds {
            most_played: (0..40).map(|i| format!("hash-{i}")).collect(),
            ..Default::default()
        };

        let playlists = generate(&seeds, wednesday());
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

        let weekday = generate(&seeds, wednesday());
        let weekend = generate(&seeds, sunday());
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
            !generate(&sparse, wednesday())
                .iter()
                .any(|p| p.id.starts_with("mood-"))
        );
    }

    #[test]
    fn deep_cuts_excludes_played_and_shuffles_deterministically_per_day() {
        let seeds = PlaylistSeeds {
            tracks: (0..10).map(|i| track(&format!("hash-{i}"), false, &[])).collect(),
            played: (0..4).map(|i| format!("hash-{i}")).collect(),
            ..Default::default()
        };

        let first = generate(&seeds, wednesday());
        let second = generate(&seeds, wednesday());
        let other_day = generate(&seeds, sunday());

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
        for played in &seeds.played {
            assert!(!cuts(&first).contains(played));
        }
        assert_eq!(cuts(&first).len(), 6);
    }
}
