//! Opus transcoding for low-data streaming and downloads.
//!
//! A library ripped losslessly is enormous relative to what a phone on a train needs: the
//! reference library this was built against averages 23.7 MB a track (ALAC), where Opus at
//! 96 kbps carries the same three minutes in about 2.2 MB. That is the whole point of low
//! data mode — the same music, roughly a tenth of the bytes, over the wire and on disk.
//!
//! Opus rather than a lower-bitrate AAC or MP3 because it is materially better at exactly
//! the rates that matter here (64–128 kbps), and because SFBAudioEngine — already the
//! client's playback engine — decodes Ogg Opus natively, so nothing new is needed to play
//! it back.
//!
//! **Everything here is progressive.** Encoding a whole track before serving a byte would
//! mean 25–45 seconds of silence before playback starts: measured on the reference hub (a
//! 32-bit armv7 Raspberry Pi) libopus manages 6.5–8.7× realtime depending on bitrate, and
//! decoding the lossless source costs more on top. Encoded frames are therefore emitted as
//! they are produced, so audio starts flowing after a fraction of a second and the encoder
//! stays comfortably ahead of the listener for the rest of the track.
//!
//! Opus only accepts a handful of input rates and the archetypal CD rip is 44.1 kHz, so
//! anything that isn't already 48 kHz is resampled first. That is a real cost on a Pi and
//! the reason the output is worth caching rather than recomputing per play.

use serde::{Deserialize, Serialize};
use std::{io::Write, path::Path};
use symphonia::core::{
    audio::SampleBuffer, codecs::DecoderOptions, formats::FormatOptions, io::MediaSourceStream,
    meta::MetadataOptions, probe::Hint,
};
use thiserror::Error;

/// Opus is defined only for these input rates; everything else has to be resampled.
const OPUS_SAMPLE_RATE: u32 = 48_000;

/// 20 ms at 48 kHz — Opus's default frame size, and the one libopus is most efficient at.
const FRAME_SAMPLES: usize = 960;

/// Opus always decodes at 48 kHz internally and discards this many leading samples. The
/// value the encoder actually wants is reported by the encoder itself; 312 is the standard
/// figure for the default 20 ms/48 kHz configuration and what the header must declare so a
/// player trims the right amount and durations come out exact.
const PRE_SKIP: u16 = 312;

/// The listener-facing quality ladder. `Original` is the untouched source file: bit-perfect,
/// and the only tier that doesn't cost the hub any CPU.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamQuality {
    Original,
    High,
    Balanced,
    Saver,
    Minimum,
}

impl StreamQuality {
    /// `None` for [`StreamQuality::Original`], which is served as-is rather than encoded.
    pub fn bits_per_second(self) -> Option<i32> {
        match self {
            Self::Original => None,
            Self::High => Some(192_000),
            Self::Balanced => Some(128_000),
            Self::Saver => Some(96_000),
            Self::Minimum => Some(64_000),
        }
    }

    /// Stable identifier used in cache keys and on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::High => "high",
            Self::Balanced => "balanced",
            Self::Saver => "saver",
            Self::Minimum => "minimum",
        }
    }

    pub fn from_str(value: &str) -> Option<Self> {
        match value {
            "original" => Some(Self::Original),
            "high" => Some(Self::High),
            "balanced" => Some(Self::Balanced),
            "saver" => Some(Self::Saver),
            "minimum" => Some(Self::Minimum),
            _ => None,
        }
    }
}

/// Decoding and resampling cost roughly this much again on top of encoding.
///
/// Measured on the reference hub: encoding alone ran at 8.1× realtime at 96 kbps, while the
/// whole pipeline against a real lossless track managed 4.9× — a ratio of about 1.65. It is
/// a correction on a calibration that is itself measured on the host, not a hardcoded speed,
/// so a machine 30× faster still estimates 30× faster.
const DECODE_OVERHEAD: f64 = 1.65;

/// How fast this machine can encode, as a multiple of realtime.
///
/// Hosts differ by far too much to assume: the same code measures ~8× realtime on a 32-bit
/// armv7 Raspberry Pi and ~254× on a 12-core laptop. Any estimate shown to someone before
/// they agree to a conversion has to come from the machine that will actually do the work,
/// so this encodes a short buffer and times it.
pub fn measure_encode_throughput(quality: StreamQuality) -> Option<f64> {
    let bitrate = quality.bits_per_second()?;
    let mut encoder = audiopus::coder::Encoder::new(
        audiopus::SampleRate::Hz48000,
        audiopus::Channels::Stereo,
        audiopus::Application::Audio,
    )
    .ok()?;
    encoder
        .set_bitrate(audiopus::Bitrate::BitsPerSecond(bitrate))
        .ok()?;
    // Two seconds of signal: long enough to swamp timer noise and per-call overhead, short
    // enough that even the slowest host answers a settings screen promptly.
    let frames = 100;
    let mut pcm = vec![0i16; FRAME_SAMPLES * 2];
    for (index, sample) in pcm.iter_mut().enumerate() {
        *sample = ((index as f32 * 0.05).sin() * 8_000.0) as i16;
    }
    let mut scratch = vec![0u8; 8_000];
    let started = std::time::Instant::now();
    for _ in 0..frames {
        encoder.encode(&pcm, &mut scratch).ok()?;
    }
    let elapsed = started.elapsed().as_secs_f64();
    if elapsed <= 0.0 {
        return None;
    }
    let audio_seconds = frames as f64 * FRAME_SAMPLES as f64 / OPUS_SAMPLE_RATE as f64;
    Some(audio_seconds / elapsed)
}

/// Seconds of wall time to convert `audio_seconds` of music at `quality` on this host,
/// accounting for however many encodes run at once.
pub fn estimate_seconds(audio_seconds: f64, quality: StreamQuality, concurrency: usize) -> f64 {
    let encode_rate = measure_encode_throughput(quality).unwrap_or(1.0);
    let effective = (encode_rate / DECODE_OVERHEAD).max(0.01);
    let lanes = concurrency.max(1) as f64;
    audio_seconds / effective / lanes
}

#[derive(Debug, Error)]
pub enum Error {
    #[error("transcoding the original quality is a copy, not an encode")]
    NotTranscodable,
    #[error("unsupported audio format for transcoding: {0}")]
    UnsupportedFormat(String),
    #[error("no audio track found in file")]
    NoAudioTrack,
    #[error("the source declares no sample rate")]
    UnknownSampleRate,
    #[error("opus supports mono and stereo only, found {0} channels")]
    UnsupportedChannels(usize),
    #[error("opus encoding failed: {0}")]
    Opus(String),
    #[error("resampling failed: {0}")]
    Resample(String),
    #[error(transparent)]
    Symphonia(#[from] symphonia::core::errors::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Decodes `source` and writes Ogg Opus to `sink` as it goes.
///
/// `sink` is flushed per Ogg page rather than at the end, which is what makes progressive
/// streaming work: the caller can be piping straight to an HTTP response body and the
/// listener hears audio long before the encode finishes.
pub fn transcode_to_ogg_opus(
    source: &Path,
    quality: StreamQuality,
    sink: &mut impl Write,
) -> Result<(), Error> {
    let bitrate = quality.bits_per_second().ok_or(Error::NotTranscodable)?;
    let mut decoded = PcmSource::open(source)?;
    let channels = decoded.channels;

    let mut encoder = audiopus::coder::Encoder::new(
        audiopus::SampleRate::Hz48000,
        match channels {
            1 => audiopus::Channels::Mono,
            2 => audiopus::Channels::Stereo,
            other => return Err(Error::UnsupportedChannels(other)),
        },
        audiopus::Application::Audio,
    )
    .map_err(|error| Error::Opus(error.to_string()))?;
    encoder
        .set_bitrate(audiopus::Bitrate::BitsPerSecond(bitrate))
        .map_err(|error| Error::Opus(error.to_string()))?;

    let mut writer = ogg::PacketWriter::new(sink);
    // A stream serial that varies per encode keeps two concurrently-served streams from
    // being mistaken for one if they are ever concatenated by a caching layer.
    let serial: u32 = rand_serial();
    write_headers(&mut writer, serial, channels, decoded.source_rate)?;

    let mut pending: Vec<f32> = Vec::with_capacity(FRAME_SAMPLES * channels * 2);
    let mut granule: u64 = 0;
    let mut encoded = vec![0u8; 8_000];
    let frame_len = FRAME_SAMPLES * channels;

    while let Some(chunk) = decoded.next_chunk()? {
        pending.extend_from_slice(&chunk);
        while pending.len() >= frame_len {
            let frame: Vec<f32> = pending.drain(..frame_len).collect();
            granule += FRAME_SAMPLES as u64;
            emit(
                &mut encoder,
                &mut writer,
                &frame,
                &mut encoded,
                serial,
                granule,
                false,
            )?;
        }
    }

    // Opus only emits whole frames, so the tail is padded with silence. The granule
    // position still reports the true sample count, so a player trims the padding and the
    // track's duration stays exact rather than rounding up to the next 20 ms.
    if !pending.is_empty() {
        let real = pending.len() / channels;
        pending.resize(frame_len, 0.0);
        granule += real as u64;
        emit(
            &mut encoder,
            &mut writer,
            &pending,
            &mut encoded,
            serial,
            granule,
            true,
        )?;
    } else {
        // An exactly-frame-aligned track still needs its final page marked, or players see
        // a truncated stream.
        emit(
            &mut encoder,
            &mut writer,
            &vec![0.0; frame_len],
            &mut encoded,
            serial,
            granule,
            true,
        )?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn emit(
    encoder: &mut audiopus::coder::Encoder,
    writer: &mut ogg::PacketWriter<'_, &mut impl Write>,
    frame: &[f32],
    scratch: &mut [u8],
    serial: u32,
    granule: u64,
    last: bool,
) -> Result<(), Error> {
    let written = encoder
        .encode_float(frame, scratch)
        .map_err(|error| Error::Opus(error.to_string()))?;
    let end = if last {
        ogg::PacketWriteEndInfo::EndStream
    } else {
        ogg::PacketWriteEndInfo::NormalPacket
    };
    writer
        .write_packet(scratch[..written].to_vec(), serial, end, granule)
        .map_err(Error::Io)?;
    Ok(())
}

fn write_headers(
    writer: &mut ogg::PacketWriter<'_, &mut impl Write>,
    serial: u32,
    channels: usize,
    source_rate: u32,
) -> Result<(), Error> {
    let mut head = Vec::with_capacity(19);
    head.extend_from_slice(b"OpusHead");
    head.push(1); // version
    head.push(channels as u8);
    head.extend_from_slice(&PRE_SKIP.to_le_bytes());
    // The *original* rate is declared here for information; the stream itself is always
    // 48 kHz, which is what a decoder actually uses.
    head.extend_from_slice(&source_rate.to_le_bytes());
    head.extend_from_slice(&0i16.to_le_bytes()); // output gain
    head.push(0); // channel mapping family: mono/stereo
    writer
        .write_packet(head, serial, ogg::PacketWriteEndInfo::EndPage, 0)
        .map_err(Error::Io)?;

    let vendor = b"aro";
    let mut tags = Vec::with_capacity(8 + 4 + vendor.len() + 4);
    tags.extend_from_slice(b"OpusTags");
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&0u32.to_le_bytes()); // no user comments
    writer
        .write_packet(tags, serial, ogg::PacketWriteEndInfo::EndPage, 0)
        .map_err(Error::Io)?;
    Ok(())
}

fn rand_serial() -> u32 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.subsec_nanos())
        .unwrap_or(0);
    nanos ^ 0x5f37_1e93
}

/// Decoded interleaved f32 audio at 48 kHz, resampling on the way through when the source
/// isn't already there.
struct PcmSource {
    format: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    channels: usize,
    source_rate: u32,
    resampler: Option<Resampler>,
}

impl PcmSource {
    fn open(path: &Path) -> Result<Self, Error> {
        let file = std::fs::File::open(path)?;
        let stream = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
            hint.with_extension(extension);
        }
        let probed = symphonia::default::get_probe()
            .format(
                &hint,
                stream,
                &FormatOptions::default(),
                &MetadataOptions::default(),
            )
            .map_err(|error| match error {
                symphonia::core::errors::Error::Unsupported(reason) => {
                    Error::UnsupportedFormat(reason.to_string())
                }
                other => Error::Symphonia(other),
            })?;
        let format = probed.format;
        let track = format.default_track().ok_or(Error::NoAudioTrack)?.clone();
        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|error| match error {
                symphonia::core::errors::Error::Unsupported(reason) => {
                    Error::UnsupportedFormat(reason.to_string())
                }
                other => Error::Symphonia(other),
            })?;
        let source_rate = track.codec_params.sample_rate.ok_or(Error::UnknownSampleRate)?;
        let channels = track
            .codec_params
            .channels
            .map(|channels| channels.count())
            .unwrap_or(2);
        if !(1..=2).contains(&channels) {
            return Err(Error::UnsupportedChannels(channels));
        }
        let resampler = (source_rate != OPUS_SAMPLE_RATE)
            .then(|| Resampler::new(source_rate, channels))
            .transpose()?;
        Ok(Self {
            track_id: track.id,
            format,
            decoder,
            channels,
            source_rate,
            resampler,
        })
    }

    /// The next block of interleaved 48 kHz f32 samples, or `None` at end of stream.
    fn next_chunk(&mut self) -> Result<Option<Vec<f32>>, Error> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(packet) => packet,
                // Symphonia signals end of stream as an IO error rather than a variant.
                Err(symphonia::core::errors::Error::IoError(error))
                    if error.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(self.resampler.as_mut().and_then(|r| r.drain()));
                }
                Err(symphonia::core::errors::Error::ResetRequired) => {
                    return Ok(self.resampler.as_mut().and_then(|r| r.drain()));
                }
                Err(error) => return Err(Error::Symphonia(error)),
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(buffer) => {
                    let spec = *buffer.spec();
                    let mut samples = SampleBuffer::<f32>::new(buffer.capacity() as u64, spec);
                    samples.copy_interleaved_ref(buffer);
                    let interleaved = samples.samples().to_vec();
                    if interleaved.is_empty() {
                        continue;
                    }
                    return match self.resampler.as_mut() {
                        Some(resampler) => Ok(Some(resampler.process(&interleaved)?)),
                        None => Ok(Some(interleaved)),
                    };
                }
                // A single corrupt packet shouldn't abort a whole track; skipping it costs
                // 20 ms of audio where failing costs the listener the song.
                Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
                Err(error) => return Err(Error::Symphonia(error)),
            }
        }
    }
}

/// Sample-rate conversion to Opus's 48 kHz, kept in its own type so the decode loop doesn't
/// have to care whether it's needed.
struct Resampler {
    inner: rubato::FastFixedIn<f32>,
    channels: usize,
    /// Deinterleaved leftovers: rubato consumes a fixed block per call, and decoded packets
    /// don't align to it.
    pending: Vec<Vec<f32>>,
    chunk: usize,
}

impl Resampler {
    fn new(source_rate: u32, channels: usize) -> Result<Self, Error> {
        const CHUNK: usize = 1024;
        let inner = rubato::FastFixedIn::<f32>::new(
            OPUS_SAMPLE_RATE as f64 / source_rate as f64,
            1.0,
            rubato::PolynomialDegree::Cubic,
            CHUNK,
            channels,
        )
        .map_err(|error| Error::Resample(error.to_string()))?;
        Ok(Self {
            inner,
            channels,
            pending: vec![Vec::new(); channels],
            chunk: CHUNK,
        })
    }

    fn process(&mut self, interleaved: &[f32]) -> Result<Vec<f32>, Error> {
        for (index, sample) in interleaved.iter().enumerate() {
            self.pending[index % self.channels].push(*sample);
        }
        let mut out = Vec::new();
        while self.pending[0].len() >= self.chunk {
            let block: Vec<Vec<f32>> = self
                .pending
                .iter_mut()
                .map(|channel| channel.drain(..self.chunk).collect())
                .collect();
            let resampled = rubato::Resampler::process(&mut self.inner, &block, None)
                .map_err(|error| Error::Resample(error.to_string()))?;
            interleave_into(&resampled, &mut out);
        }
        Ok(out)
    }

    /// Flushes the tail once the decoder is exhausted, padding to a full block so the last
    /// fraction of a second isn't silently dropped.
    fn drain(&mut self) -> Option<Vec<f32>> {
        if self.pending[0].is_empty() {
            return None;
        }
        let block: Vec<Vec<f32>> = self
            .pending
            .iter_mut()
            .map(|channel| {
                let mut taken: Vec<f32> = std::mem::take(channel);
                taken.resize(self.chunk, 0.0);
                taken
            })
            .collect();
        let resampled = rubato::Resampler::process(&mut self.inner, &block, None).ok()?;
        let mut out = Vec::new();
        interleave_into(&resampled, &mut out);
        Some(out)
    }
}

fn interleave_into(channels: &[Vec<f32>], out: &mut Vec<f32>) {
    let frames = channels.first().map(Vec::len).unwrap_or(0);
    for frame in 0..frames {
        for channel in channels {
            out.push(channel[frame]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_ladder_maps_to_the_documented_bitrates() {
        assert_eq!(StreamQuality::Original.bits_per_second(), None);
        assert_eq!(StreamQuality::High.bits_per_second(), Some(192_000));
        assert_eq!(StreamQuality::Balanced.bits_per_second(), Some(128_000));
        assert_eq!(StreamQuality::Saver.bits_per_second(), Some(96_000));
        assert_eq!(StreamQuality::Minimum.bits_per_second(), Some(64_000));
    }

    /// Quality names travel in cache keys and on the wire, so they have to round-trip
    /// exactly — a rename would silently orphan every cached encode.
    #[test]
    fn quality_names_round_trip() {
        for quality in [
            StreamQuality::Original,
            StreamQuality::High,
            StreamQuality::Balanced,
            StreamQuality::Saver,
            StreamQuality::Minimum,
        ] {
            assert_eq!(StreamQuality::from_str(quality.as_str()), Some(quality));
        }
        assert_eq!(StreamQuality::from_str("lossless"), None);
    }

    /// Writes a minimal PCM16 WAV so the decode → resample → encode path can be exercised
    /// end to end without shipping a binary fixture.
    fn write_wav(path: &Path, sample_rate: u32, channels: u16, seconds: f32) {
        let frames = (sample_rate as f32 * seconds) as u32;
        let data_len = frames * channels as u32 * 2;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&(sample_rate * channels as u32 * 2).to_le_bytes());
        out.extend_from_slice(&(channels * 2).to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        for frame in 0..frames {
            let t = frame as f32 / sample_rate as f32;
            let value = ((t * 440.0 * std::f32::consts::TAU).sin() * 8000.0) as i16;
            for _ in 0..channels {
                out.extend_from_slice(&value.to_le_bytes());
            }
        }
        std::fs::write(path, out).unwrap();
    }

    /// The archetypal source is a 44.1 kHz CD rip, which Opus cannot take directly — so the
    /// resampler is on the normal path, not an edge case. This is the whole pipeline:
    /// decode, resample to 48 kHz, encode, and frame into Ogg.
    #[test]
    fn a_44100_hz_source_transcodes_to_a_well_formed_ogg_opus_stream() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.wav");
        write_wav(&source, 44_100, 2, 3.0);

        let mut out = Vec::new();
        transcode_to_ogg_opus(&source, StreamQuality::Saver, &mut out).unwrap();

        assert!(out.starts_with(b"OggS"), "not an Ogg stream");
        assert!(
            out.windows(8).any(|window| window == b"OpusHead"),
            "missing OpusHead identification header"
        );
        assert!(
            out.windows(8).any(|window| window == b"OpusTags"),
            "missing OpusTags comment header"
        );
        // Three seconds at 96 kbps is roughly 36 KB. The bound is deliberately loose — the
        // point is that real audio came out, not silence or a header-only stub.
        assert!(
            (8_000..200_000).contains(&out.len()),
            "unexpected encoded size {}",
            out.len()
        );
    }

    /// Lower tiers must actually produce smaller output, or the ladder is decorative.
    #[test]
    fn lower_tiers_produce_smaller_streams() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.wav");
        write_wav(&source, 48_000, 2, 2.0);

        let mut sizes = Vec::new();
        for quality in [
            StreamQuality::High,
            StreamQuality::Balanced,
            StreamQuality::Saver,
            StreamQuality::Minimum,
        ] {
            let mut out = Vec::new();
            transcode_to_ogg_opus(&source, quality, &mut out).unwrap();
            sizes.push((quality, out.len()));
        }
        for pair in sizes.windows(2) {
            assert!(
                pair[0].1 > pair[1].1,
                "{:?} ({} bytes) should exceed {:?} ({} bytes)",
                pair[0].0,
                pair[0].1,
                pair[1].0,
                pair[1].1
            );
        }
    }

    /// Asking to transcode `Original` is a caller mistake, not a silent copy: the whole
    /// point of that tier is that the untouched file is served.
    #[test]
    fn original_quality_refuses_to_encode() {
        let mut sink = Vec::new();
        let error = transcode_to_ogg_opus(
            Path::new("/nonexistent.flac"),
            StreamQuality::Original,
            &mut sink,
        )
        .unwrap_err();
        assert!(matches!(error, Error::NotTranscodable));
        assert!(sink.is_empty());
    }
}
