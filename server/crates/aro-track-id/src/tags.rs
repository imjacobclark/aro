//! Optional write-back of identified metadata into the original audio file's tags.
//!
//! Off by default (see the `persist_metadata_to_files` setting, toggled from the
//! macOS app's Settings UI). Only ever updates existing tag fields in place via
//! lofty's tag API — never a destructive re-encode of the audio itself — and is only
//! attempted against files aro can currently reach (see
//! `HubStore::live_path_for_track`). Aro's own database remains the source of truth
//! either way; this is a convenience for users who want their files to carry the
//! identified metadata outside of Aro.

use aro_sync_store::HubStore;
use lofty::{
    config::WriteOptions,
    file::TaggedFileExt,
    prelude::{Accessor, ItemKey, TagExt},
    probe::Probe,
};
use serde_json::{Map, Value};
use std::path::Path;

pub const PERSIST_METADATA_SETTING: &str = "persist_metadata_to_files";

pub fn should_persist_to_files(store: &HubStore) -> Result<bool, aro_sync_store::StoreError> {
    Ok(store
        .setting(PERSIST_METADATA_SETTING)?
        .and_then(|value| value.as_bool())
        .unwrap_or(false))
}

/// The file's own existing tags, read as a best-effort disambiguation hint — never
/// persisted, never a substitute for identification. All fields are `None` if the file has
/// no tag at all or the specific field is absent, which callers treat as "no hint
/// available."
#[derive(Debug, Clone, Default)]
pub struct ExistingTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    /// Weak evidence, deliberately low-weighted wherever it's used: compilation rips
    /// routinely carry the *original* album's track numbering rather than the compilation's,
    /// so this alone can't be trusted to place a file within a specific release.
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
}

/// Best-effort read of the file's own existing tags. See [`ExistingTags`] for what each
/// field means as a hint and why.
///
/// Title and artist disambiguate which *recording* a fingerprint match points at
/// (see `acoustid::best_match`) — a fingerprint cluster can carry multiple
/// recordings by the same artist too (e.g. several tracks off the same album), so
/// artist alone doesn't always pin down the right one. Album disambiguates which
/// *release* of that recording to use (see `musicbrainz::select_release`): a
/// recording is typically attached to many releases — the original studio album,
/// but also singles/EPs that happen to include the same recording — and MusicBrainz
/// doesn't reliably mark which one is "the" album. The file's own existing album
/// tag is often the strongest signal available for that, especially for tracks
/// whose only "official album" release in MusicBrainz is actually a single.
pub fn read_existing_tags(path: &Path) -> ExistingTags {
    let Some(tagged) = Probe::open(path).ok().and_then(|probe| probe.read().ok()) else {
        return ExistingTags::default();
    };
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return ExistingTags::default();
    };
    ExistingTags {
        title: tag.title().map(|value| value.into_owned()),
        artist: tag.artist().map(|value| value.into_owned()),
        album: tag.album().map(|value| value.into_owned()),
        album_artist: tag.get_string(ItemKey::AlbumArtist).map(str::to_owned),
        track_number: tag.track(),
        disc_number: tag.disk(),
    }
}

pub fn write_back(path: &Path, fields: &Map<String, Value>) -> anyhow::Result<()> {
    let mut tagged = Probe::open(path)?.read()?;
    let has_primary_tag = tagged.primary_tag().is_some();
    let Some(tag) = (if has_primary_tag {
        tagged.primary_tag_mut()
    } else {
        tagged.first_tag_mut()
    }) else {
        return Ok(());
    };
    if let Some(title) = fields.get("title").and_then(Value::as_str) {
        tag.set_title(title.to_string());
    }
    if let Some(artist) = fields.get("artist").and_then(Value::as_str) {
        tag.set_artist(artist.to_string());
    }
    if let Some(album) = fields.get("album").and_then(Value::as_str) {
        tag.set_album(album.to_string());
    }
    tag.save_to_path(path, WriteOptions::default())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lofty::tag::{Tag, TagType};
    use std::io::Write;

    /// A minimal valid silent WAV — this is purely a container for lofty to attach a tag
    /// to, same approach as `fingerprint.rs`'s synthetic WAV helper but private to this
    /// module since tags don't need real audio content. A *zero-length* `data` chunk is
    /// rejected by lofty's WAV decoder ("File does not contain a \"data\" chunk", verified
    /// directly), so this writes a small amount of actual silent sample data rather than an
    /// empty chunk.
    fn write_silent_wav(path: &Path) {
        let mut file = std::fs::File::create(path).unwrap();
        let sample_rate: u32 = 44_100;
        let channels: u16 = 1;
        let bits_per_sample: u16 = 16;
        let byte_rate = sample_rate * u32::from(channels) * u32::from(bits_per_sample) / 8;
        let block_align = channels * bits_per_sample / 8;
        let data = vec![0u8; 200];

        file.write_all(b"RIFF").unwrap();
        file.write_all(&(36 + data.len() as u32).to_le_bytes())
            .unwrap();
        file.write_all(b"WAVE").unwrap();
        file.write_all(b"fmt ").unwrap();
        file.write_all(&16u32.to_le_bytes()).unwrap();
        file.write_all(&1u16.to_le_bytes()).unwrap(); // PCM
        file.write_all(&channels.to_le_bytes()).unwrap();
        file.write_all(&sample_rate.to_le_bytes()).unwrap();
        file.write_all(&byte_rate.to_le_bytes()).unwrap();
        file.write_all(&block_align.to_le_bytes()).unwrap();
        file.write_all(&bits_per_sample.to_le_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&(data.len() as u32).to_le_bytes()).unwrap();
        file.write_all(&data).unwrap();
    }

    #[test]
    fn read_existing_tags_reads_track_and_disc_numbers() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tagged.wav");
        write_silent_wav(&path);

        let mut tag = Tag::new(TagType::Id3v2);
        tag.set_title("December".to_string());
        tag.set_artist("Neck Deep".to_string());
        tag.set_album("Life's Not Out to Get You".to_string());
        tag.insert_text(ItemKey::AlbumArtist, "Neck Deep".to_string());
        tag.set_track(9);
        tag.set_disk(1);
        tag.save_to_path(&path, WriteOptions::default()).unwrap();

        let read = read_existing_tags(&path);

        assert_eq!(read.title.as_deref(), Some("December"));
        assert_eq!(read.artist.as_deref(), Some("Neck Deep"));
        assert_eq!(read.album.as_deref(), Some("Life's Not Out to Get You"));
        assert_eq!(read.album_artist.as_deref(), Some("Neck Deep"));
        assert_eq!(read.track_number, Some(9));
        assert_eq!(read.disc_number, Some(1));
    }

    #[test]
    fn read_existing_tags_on_untagged_file_returns_all_none() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("untagged.wav");
        write_silent_wav(&path);

        let read = read_existing_tags(&path);

        assert!(read.title.is_none());
        assert!(read.artist.is_none());
        assert!(read.album.is_none());
        assert!(read.album_artist.is_none());
        assert!(read.track_number.is_none());
        assert!(read.disc_number.is_none());
    }
}
