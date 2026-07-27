use lofty::{
    file::{AudioFile, TaggedFileExt},
    prelude::Accessor,
    probe::Probe,
};
use serde_json::{Map, Value, json};
use std::path::Path;

pub(crate) fn song_payload(
    file: &Path,
    content_hash: &str,
    byte_count: u64,
    source_id: uuid::Uuid,
) -> Value {
    let fallback_title = file
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Unknown");
    let extension = file
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("audio")
        .to_lowercase();
    let mut payload = Map::from_iter([
        ("content_hash".into(), json!(content_hash)),
        ("byte_count".into(), json!(byte_count)),
        ("title".into(), json!(fallback_title)),
        (
            "original_filename".into(),
            json!(
                file.file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("Unknown")
            ),
        ),
        ("original_extension".into(), json!(extension)),
        ("source_id".into(), json!(source_id)),
    ]);

    let Ok(tagged) = Probe::open(file).and_then(Probe::read) else {
        return Value::Object(payload);
    };
    let properties = tagged.properties();
    insert_optional(
        &mut payload,
        "sample_rate",
        properties.sample_rate().map(Value::from),
    );
    insert_optional(
        &mut payload,
        "bit_depth",
        properties.bit_depth().map(Value::from),
    );
    insert_optional(
        &mut payload,
        "channel_count",
        properties.channels().map(Value::from),
    );
    insert_optional(
        &mut payload,
        "bitrate",
        properties
            .audio_bitrate()
            .or_else(|| properties.overall_bitrate())
            .map(|kbps| Value::from(f64::from(kbps) * 1_000.0)),
    );
    if !properties.duration().is_zero() {
        payload.insert(
            "duration".into(),
            Value::from(properties.duration().as_secs_f64()),
        );
    }
    payload.insert("codec".into(), Value::from(extension));

    if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
        insert_nonempty(&mut payload, "title", tag.title());
        insert_nonempty(&mut payload, "artist", tag.artist());
        insert_nonempty(&mut payload, "album", tag.album());
        if let Some(date) = tag.date() {
            payload.insert("release_year".into(), Value::from(date.year));
        }
        if let Some(track) = tag.track() {
            payload.insert("track_number".into(), Value::from(track));
        }
        if let Some(disc) = tag.disk() {
            payload.insert("disc_number".into(), Value::from(disc));
        }
    }

    Value::Object(payload)
}

fn insert_optional(payload: &mut Map<String, Value>, field: &str, value: Option<Value>) {
    if let Some(value) = value {
        payload.insert(field.into(), value);
    }
}

fn insert_nonempty(
    payload: &mut Map<String, Value>,
    field: &str,
    value: Option<std::borrow::Cow<'_, str>>,
) {
    if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
        payload.insert(field.into(), Value::from(value.into_owned()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_playback_properties_from_audio_header() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("Sample.wav");
        let sample_rate = 44_100_u32;
        let channels = 2_u16;
        let bit_depth = 16_u16;
        let data_size = sample_rate * u32::from(channels) * u32::from(bit_depth / 8);
        let mut wav = Vec::with_capacity(44 + data_size as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_size).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&channels.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(
            &(sample_rate * u32::from(channels) * u32::from(bit_depth / 8)).to_le_bytes(),
        );
        wav.extend_from_slice(&(channels * (bit_depth / 8)).to_le_bytes());
        wav.extend_from_slice(&bit_depth.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_size.to_le_bytes());
        wav.resize(44 + data_size as usize, 0);
        std::fs::write(&file, wav).unwrap();

        let payload = song_payload(&file, "hash", u64::from(data_size), uuid::Uuid::new_v4());

        assert_eq!(payload["sample_rate"], 44_100);
        assert_eq!(payload["bit_depth"], 16);
        assert_eq!(payload["channel_count"], 2);
        assert_eq!(payload["codec"], "wav");
        assert_eq!(payload["duration"], 1.0);
    }
}
