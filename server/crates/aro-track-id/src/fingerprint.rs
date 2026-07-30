//! Decodes an audio file and computes an AcoustID-compatible Chromaprint fingerprint.
//!
//! Uses `symphonia` for decoding (pure Rust) and binds the real `libchromaprint` C
//! library for the fingerprint algorithm itself, via a small hand-written FFI layer —
//! not a pure-Rust reimplementation. That wasn't the original plan (see git history):
//! `rusty-chromaprint`, a clean-room Rust port, was tried first specifically to avoid
//! LGPL-linking and native-dylib questions, but direct comparison against real
//! `fpcalc` output on real files showed its raw hashes are close but not bit-identical
//! to the C reference — confirmed upstream as a known limitation (it "uses a different
//! resampler" and deliberately "doesn't reproduce certain C bugs needed for database
//! compatibility"). AcoustID's server matches against fingerprints produced by the
//! real library, bugs and all, so nothing short of the real library actually works.
//! `libchromaprint` is LGPLv2.1 — linked dynamically here specifically so that stays
//! compliant (users can relink a different build of the library; static linking would
//! not afford that).
//!
//! Symphonia still does the decoding: it covers every format `sources.rs` accepts
//! except Monkey's Audio (.ape), WavPack (.wv), and DSD (.dsf/.dff), so files in those
//! formats are skipped for identification (returns `Error::UnsupportedFormat`) rather
//! than causing a failure elsewhere in the pipeline.

use std::{
    ffi::{CStr, c_char, c_int, c_void},
    path::Path,
};
use symphonia::core::{
    audio::{AudioBufferRef, Signal},
    codecs::DecoderOptions,
    formats::FormatOptions,
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
};
use thiserror::Error;

/// `CHROMAPRINT_ALGORITHM_TEST2` — the standard algorithm real clients (fpcalc,
/// MusicBrainz Picard) submit to AcoustID with. `TEST1` (0) is an older/experimental
/// variant AcoustID's backend rejects as "invalid fingerprint".
const CHROMAPRINT_ALGORITHM_TEST2: c_int = 1;

unsafe extern "C" {
    fn chromaprint_new(algorithm: c_int) -> *mut c_void;
    fn chromaprint_free(ctx: *mut c_void);
    fn chromaprint_start(ctx: *mut c_void, sample_rate: c_int, num_channels: c_int) -> c_int;
    fn chromaprint_feed(ctx: *mut c_void, data: *const i16, size: c_int) -> c_int;
    fn chromaprint_finish(ctx: *mut c_void) -> c_int;
    fn chromaprint_get_fingerprint(ctx: *mut c_void, fingerprint: *mut *mut c_char) -> c_int;
    fn chromaprint_dealloc(ptr: *mut c_void);
}

struct ChromaprintContext(*mut c_void);

impl ChromaprintContext {
    fn new() -> Result<Self, Error> {
        let ctx = unsafe { chromaprint_new(CHROMAPRINT_ALGORITHM_TEST2) };
        if ctx.is_null() {
            return Err(Error::Chromaprint("chromaprint_new returned null".into()));
        }
        Ok(Self(ctx))
    }
}

impl Drop for ChromaprintContext {
    fn drop(&mut self) {
        unsafe { chromaprint_free(self.0) };
    }
}

#[derive(Debug, Error)]
pub enum Error {
    #[error("unsupported audio format for fingerprinting: {0}")]
    UnsupportedFormat(String),
    #[error("no audio track found in file")]
    NoAudioTrack,
    #[error("decoding produced no samples")]
    Empty,
    #[error("chromaprint error: {0}")]
    Chromaprint(String),
    #[error(transparent)]
    Symphonia(#[from] symphonia::core::errors::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug)]
pub struct FingerprintResult {
    pub fingerprint_base64: String,
    pub duration_secs: u32,
}

/// Decodes `path` and computes its Chromaprint fingerprint, encoded exactly as the
/// AcoustID web service expects for the `fingerprint` lookup parameter (real
/// `libchromaprint`'s own compressed-and-base64 output — no re-implementation of the
/// compression/encoding step here, deliberately, for the same bit-exactness reason
/// the algorithm itself is FFI-bound rather than reimplemented).
pub fn fingerprint_file(path: &Path) -> Result<FingerprintResult, Error> {
    let file = std::fs::File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
        hint.with_extension(extension);
    }

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|error| match error {
            symphonia::core::errors::Error::Unsupported(reason) => {
                Error::UnsupportedFormat(reason.to_string())
            }
            other => Error::Symphonia(other),
        })?;
    let mut format = probed.format;

    let track = format.default_track().ok_or(Error::NoAudioTrack)?.clone();
    let track_id = track.id;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|error| match error {
            symphonia::core::errors::Error::Unsupported(reason) => {
                Error::UnsupportedFormat(reason.to_string())
            }
            other => Error::Symphonia(other),
        })?;

    // Chromaprint needs a sample rate and channel count up front, but neither is
    // reliably present in `track.codec_params` for every container/codec pairing —
    // observed directly: ALAC-in-MP4 (.m4a) files probe fine but leave `channels`
    // (and sometimes `sample_rate`) as `None` at the container level; symphonia only
    // exposes the real values via the decoded buffer's `spec()` once the first
    // packet is actually decoded. Every .m4a in the library was silently failing
    // fingerprinting because of this before decoding a single packet. So: create
    // the chromaprint context lazily, from the first successfully decoded packet's
    // spec, which is always accurate regardless of what the container declared.
    let mut context: Option<ChromaprintContext> = None;
    let mut sample_rate: u32 = 0;
    let mut interleaved = Vec::<i16>::new();
    let mut total_frames: u64 = 0;
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(symphonia::core::errors::Error::IoError(error))
                if error.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(symphonia::core::errors::Error::ResetRequired) => break,
            Err(error) => return Err(error.into()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
            Err(error) => return Err(error.into()),
        };

        if context.is_none() {
            let spec = decoded.spec();
            sample_rate = spec.rate;
            let channels = spec.channels.count() as c_int;
            let new_context = ChromaprintContext::new()?;
            if unsafe { chromaprint_start(new_context.0, sample_rate as c_int, channels) } == 0 {
                return Err(Error::Chromaprint("chromaprint_start failed".into()));
            }
            context = Some(new_context);
        }
        let active_context = context.as_ref().expect("initialized above");

        total_frames += decoded.frames() as u64;
        interleaved.extend(to_interleaved_i16(&decoded));
        let fed = unsafe {
            chromaprint_feed(
                active_context.0,
                interleaved.as_ptr(),
                interleaved.len() as c_int,
            )
        };
        if fed == 0 {
            return Err(Error::Chromaprint("chromaprint_feed failed".into()));
        }
        interleaved.clear();
    }

    if total_frames == 0 {
        return Err(Error::Empty);
    }
    let context = context.expect("total_frames > 0 implies at least one packet was decoded");

    if unsafe { chromaprint_finish(context.0) } == 0 {
        return Err(Error::Chromaprint("chromaprint_finish failed".into()));
    }

    let mut raw_fingerprint: *mut c_char = std::ptr::null_mut();
    if unsafe { chromaprint_get_fingerprint(context.0, &mut raw_fingerprint) } == 0 {
        return Err(Error::Chromaprint(
            "chromaprint_get_fingerprint failed".into(),
        ));
    }
    let fingerprint_base64 = unsafe {
        let owned = CStr::from_ptr(raw_fingerprint)
            .to_string_lossy()
            .into_owned();
        chromaprint_dealloc(raw_fingerprint.cast());
        owned
    };
    let duration_secs = (total_frames / u64::from(sample_rate)).clamp(1, u32::MAX as u64) as u32;

    Ok(FingerprintResult {
        fingerprint_base64,
        duration_secs,
    })
}

/// Converts a decoded audio buffer of any sample format into interleaved i16 samples,
/// the format `chromaprint_feed` expects.
fn to_interleaved_i16(decoded: &AudioBufferRef<'_>) -> Vec<i16> {
    use symphonia::core::conv::IntoSample;

    macro_rules! interleave {
        ($buffer:expr) => {{
            let spec = $buffer.spec();
            let channels = spec.channels.count();
            let frames = $buffer.frames();
            let mut out = Vec::with_capacity(frames * channels);
            for frame in 0..frames {
                for channel in 0..channels {
                    let sample: i16 = $buffer.chan(channel)[frame].into_sample();
                    out.push(sample);
                }
            }
            out
        }};
    }

    match decoded {
        AudioBufferRef::U8(buffer) => interleave!(buffer),
        AudioBufferRef::U16(buffer) => interleave!(buffer),
        AudioBufferRef::U24(buffer) => interleave!(buffer),
        AudioBufferRef::U32(buffer) => interleave!(buffer),
        AudioBufferRef::S8(buffer) => interleave!(buffer),
        AudioBufferRef::S16(buffer) => interleave!(buffer),
        AudioBufferRef::S24(buffer) => interleave!(buffer),
        AudioBufferRef::S32(buffer) => interleave!(buffer),
        AudioBufferRef::F32(buffer) => interleave!(buffer),
        AudioBufferRef::F64(buffer) => interleave!(buffer),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Writes a short synthetic sine-wave WAV, matching the WAV-construction pattern
    /// used by `aro-server`'s own `audio_metadata` tests, so this test exercises the
    /// real symphonia decode + libchromaprint FFI pipeline end to end without needing
    /// a real music file fixture.
    fn write_sine_wav(path: &Path, sample_rate: u32, channels: u16, seconds: f32) {
        let frame_count = (sample_rate as f32 * seconds) as u32;
        let bit_depth = 16_u16;
        let data_size = frame_count * u32::from(channels) * u32::from(bit_depth / 8);
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

        for frame in 0..frame_count {
            let t = frame as f32 / sample_rate as f32;
            let sample = (t * 440.0 * std::f32::consts::TAU).sin();
            let value = (sample * i16::MAX as f32) as i16;
            for _ in 0..channels {
                wav.extend_from_slice(&value.to_le_bytes());
            }
        }
        std::fs::write(path, wav).unwrap();
    }

    #[test]
    fn fingerprints_a_synthetic_wav() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tone.wav");
        write_sine_wav(&path, 44_100, 2, 5.0);

        let result = fingerprint_file(&path).expect("fingerprinting should succeed");

        assert!(
            !result.fingerprint_base64.is_empty(),
            "expected a non-empty compressed fingerprint"
        );
        assert!(
            result.duration_secs >= 4 && result.duration_secs <= 6,
            "expected duration close to 5s, got {}",
            result.duration_secs
        );
    }

    #[test]
    fn unsupported_format_is_a_typed_error_not_a_panic() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("not-audio.txt");
        std::fs::write(&path, b"this is not an audio file").unwrap();

        let error = fingerprint_file(&path).expect_err("plain text should not fingerprint");
        assert!(matches!(
            error,
            Error::UnsupportedFormat(_) | Error::Symphonia(_) | Error::Io(_)
        ));
    }
}
