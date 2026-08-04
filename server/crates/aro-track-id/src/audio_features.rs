//! Background engineered audio-feature analysis — Tier 2/3 of
//! `listening-intelligence-roadmap.md`: measured tempo, energy, brightness, dynamic
//! range, and a timbre/harmony feature vector (MFCC + chroma), all derived from one
//! FFT pass over the decoded audio. Deliberately **not** a learned embedding model —
//! no CoreML, no ONNX Runtime, no model file to ship or license. This is classic MIR
//! (music information retrieval): the same hand-engineered descriptors audio
//! similarity used before deep learning existed, computed as plain arithmetic over an
//! FFT `rustfft` (pure Rust) already provides. That means this code runs identically
//! on a Raspberry Pi 2, a Mac, or Windows — there is no platform-specific runtime to
//! diverge, and no hardware tier this can't run on.
//!
//! Tier 2 consumes the scalar fields (`tempo_bpm`, `energy_mean`, `brightness`,
//! `dynamic_range`, `danceability`) for measured Workout/Chill playlists and
//! tempo-coherent ordering. Tier 3 consumes the full vector (via [`AudioFeatures::vector`])
//! for k-means clustering (Daily Mixes) and nearest-neighbour similarity (seed-track
//! radio) — see `aro-server`'s `playlists` module for both.

use rustfft::{FftPlanner, num_complex::Complex};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use symphonia::core::{
    audio::SampleBuffer, codecs::DecoderOptions, formats::FormatOptions, io::MediaSourceStream,
    meta::MetadataOptions, probe::Hint,
};
use thiserror::Error;
use tokio::sync::{Mutex, mpsc};

pub const ALGORITHM_VERSION: i64 = 1;

const FRAME_SIZE: usize = 2_048;
const HOP_SIZE: usize = 512;
const MEL_BANDS: usize = 26;
const MFCC_COUNT: usize = 13;
const CHROMA_BINS: usize = 12;

/// Rather than decoding an entire track, analysis covers a representative excerpt —
/// standard MIR practice, and what keeps this tractable on weak hardware (a Raspberry
/// Pi 2) without materially hurting feature quality. The offset skips a likely silent
/// or fading-in intro.
const ANALYSIS_OFFSET_SECS: f64 = 15.0;
const ANALYSIS_DURATION_SECS: f64 = 90.0;
/// A track shorter than this just gets analyzed in full — skipping 15s into a short
/// track could skip past all of it.
const MIN_TRACK_SECS_FOR_OFFSET: f64 = 45.0;

const MIN_TEMPO_BPM: f64 = 60.0;
const MAX_TEMPO_BPM: f64 = 200.0;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioFeatures {
    pub tempo_bpm: f64,
    pub energy_mean: f64,
    pub energy_variance: f64,
    /// Mean spectral centroid, normalized to roughly `[0, 1]` (divided by Nyquist) so
    /// it's comparable across tracks at different sample rates.
    pub brightness: f64,
    /// Crest factor in dB (`20 * log10(peak / rms)`) — higher means peakier/more
    /// dynamic, lower means more compressed/loud-throughout.
    pub dynamic_range: f64,
    /// Regularity of the detected beat (best autocorrelation over the mean) — a
    /// relative, library-internal proxy, not a calibrated absolute scale.
    pub danceability: f64,
    /// 13 MFCC means followed by 13 MFCC variances across analyzed frames.
    pub mfcc: Vec<f64>,
    /// Mean 12-bin chroma (pitch-class) profile across analyzed frames.
    pub chroma: Vec<f64>,
}

impl AudioFeatures {
    /// The full similarity feature vector Tier 3 clusters/nearest-neighbours over:
    /// the scalar features followed by MFCC then chroma. Fixed length
    /// (5 + 26 + 12 = 43) regardless of track content, so every track's vector is
    /// directly comparable.
    pub fn vector(&self) -> Vec<f64> {
        let mut vector = vec![
            self.tempo_bpm / 200.0, // rough normalization to a similar scale to the rest
            self.energy_mean,
            self.brightness,
            self.dynamic_range / 40.0,
            self.danceability,
        ];
        vector.extend_from_slice(&self.mfcc);
        vector.extend_from_slice(&self.chroma);
        vector
    }
}

#[derive(Debug, Error)]
pub enum Error {
    #[error("unsupported audio format for feature analysis: {0}")]
    UnsupportedFormat(String),
    #[error("no audio track found in file")]
    NoAudioTrack,
    #[error("decoding produced too little audio for a feature analysis")]
    TooShort,
    #[error(transparent)]
    Symphonia(#[from] symphonia::core::errors::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub fn analyze_file(path: &Path) -> Result<AudioFeatures, Error> {
    let (samples, sample_rate) = decode_mono(path)?;
    analyze_samples(&samples, sample_rate)
}

/// Decodes `path` to a single channel of `f32` samples (channels averaged down to
/// mono — feature extraction cares about timbre/rhythm, not stereo image).
fn decode_mono(path: &Path) -> Result<(Vec<f32>, u32), Error> {
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

    let mut mono_samples: Vec<f32> = Vec::new();
    let mut sample_rate = 0_u32;
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
        let spec = *decoded.spec();
        sample_rate = spec.rate;
        let channel_count = spec.channels.count().max(1);
        let mut samples = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        samples.copy_interleaved_ref(decoded);
        let interleaved = samples.samples();
        for frame in interleaved.chunks_exact(channel_count) {
            let sum: f32 = frame.iter().sum();
            mono_samples.push(sum / channel_count as f32);
        }
    }

    if sample_rate == 0 || mono_samples.is_empty() {
        return Err(Error::TooShort);
    }
    Ok((mono_samples, sample_rate))
}

fn analyze_samples(samples: &[f32], sample_rate: u32) -> Result<AudioFeatures, Error> {
    let excerpt = select_excerpt(samples, sample_rate);
    if excerpt.len() < FRAME_SIZE {
        return Err(Error::TooShort);
    }

    let peak_amplitude = excerpt
        .iter()
        .fold(0.0_f32, |max, sample| max.max(sample.abs()));
    let overall_rms = rms(excerpt);

    let window = hann_window(FRAME_SIZE);
    let mel_filters = mel_filterbank(sample_rate, FRAME_SIZE, MEL_BANDS);
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FRAME_SIZE);

    let mut frame_energies: Vec<f64> = Vec::new();
    let mut frame_centroids: Vec<f64> = Vec::new();
    let mut onset_envelope: Vec<f64> = Vec::new();
    let mut mfcc_frames: Vec<[f64; MFCC_COUNT]> = Vec::new();
    let mut chroma_frames: Vec<[f64; CHROMA_BINS]> = Vec::new();
    let mut previous_magnitudes: Option<Vec<f32>> = None;

    let mut start = 0;
    let mut buffer = vec![
        Complex {
            re: 0.0_f32,
            im: 0.0_f32
        };
        FRAME_SIZE
    ];
    while start + FRAME_SIZE <= excerpt.len() {
        let frame = &excerpt[start..start + FRAME_SIZE];
        frame_energies.push(f64::from(rms(frame)));

        for (index, sample) in frame.iter().enumerate() {
            buffer[index] = Complex {
                re: sample * window[index],
                im: 0.0,
            };
        }
        fft.process(&mut buffer);
        let bin_count = FRAME_SIZE / 2 + 1;
        let magnitudes: Vec<f32> = buffer[..bin_count].iter().map(|c| c.norm()).collect();

        frame_centroids.push(spectral_centroid(&magnitudes, sample_rate, FRAME_SIZE));
        mfcc_frames.push(mfcc(&magnitudes, &mel_filters));
        chroma_frames.push(chroma(&magnitudes, sample_rate, FRAME_SIZE));

        if let Some(previous) = &previous_magnitudes {
            let flux: f64 = magnitudes
                .iter()
                .zip(previous.iter())
                .map(|(current, previous)| f64::from((current - previous).max(0.0)))
                .sum();
            onset_envelope.push(flux);
        }
        previous_magnitudes = Some(magnitudes);

        start += HOP_SIZE;
    }

    if frame_energies.is_empty() {
        return Err(Error::TooShort);
    }

    let (energy_mean, energy_variance) = mean_and_variance(&frame_energies);
    let nyquist = f64::from(sample_rate) / 2.0;
    let brightness = if nyquist > 0.0 {
        (frame_centroids.iter().sum::<f64>() / frame_centroids.len() as f64) / nyquist
    } else {
        0.0
    };
    let dynamic_range = if overall_rms > 0.0 {
        f64::from(20.0 * (peak_amplitude / overall_rms).log10())
    } else {
        0.0
    };

    let frame_rate = f64::from(sample_rate) / HOP_SIZE as f64;
    let (tempo_bpm, danceability) = estimate_tempo(&onset_envelope, frame_rate);

    let mfcc_vector = aggregate_frames::<MFCC_COUNT>(&mfcc_frames);
    let chroma_vector = aggregate_chroma(&chroma_frames);

    Ok(AudioFeatures {
        tempo_bpm,
        energy_mean: f64::from(energy_mean),
        energy_variance: f64::from(energy_variance),
        brightness,
        dynamic_range,
        danceability,
        mfcc: mfcc_vector,
        chroma: chroma_vector,
    })
}

/// Picks the representative excerpt to analyze — see the module-level doc comment.
fn select_excerpt(samples: &[f32], sample_rate: u32) -> &[f32] {
    let total_secs = samples.len() as f64 / f64::from(sample_rate);
    if total_secs <= MIN_TRACK_SECS_FOR_OFFSET {
        return samples;
    }
    let start = (ANALYSIS_OFFSET_SECS * f64::from(sample_rate)) as usize;
    let end =
        (start + (ANALYSIS_DURATION_SECS * f64::from(sample_rate)) as usize).min(samples.len());
    &samples[start.min(samples.len())..end]
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = samples.iter().map(|s| f64::from(*s) * f64::from(*s)).sum();
    (sum_sq / samples.len() as f64).sqrt() as f32
}

fn mean_and_variance(values: &[f64]) -> (f32, f32) {
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    let variance = values
        .iter()
        .map(|value| (value - mean).powi(2))
        .sum::<f64>()
        / values.len() as f64;
    (mean as f32, variance as f32)
}

fn hann_window(size: usize) -> Vec<f32> {
    (0..size)
        .map(|i| {
            0.5 - 0.5
                * (2.0 * std::f32::consts::PI * i as f32 / (size.saturating_sub(1)) as f32).cos()
        })
        .collect()
}

fn spectral_centroid(magnitudes: &[f32], sample_rate: u32, frame_size: usize) -> f64 {
    let mut weighted_sum = 0.0_f64;
    let mut total = 0.0_f64;
    for (bin, magnitude) in magnitudes.iter().enumerate() {
        let freq = bin as f64 * f64::from(sample_rate) / frame_size as f64;
        let magnitude = f64::from(*magnitude);
        weighted_sum += freq * magnitude;
        total += magnitude;
    }
    if total > 0.0 {
        weighted_sum / total
    } else {
        0.0
    }
}

/// Triangular mel filterbank — `bands` filters spanning 0 Hz to Nyquist, each row
/// weighting the FFT bins it covers.
fn mel_filterbank(sample_rate: u32, frame_size: usize, bands: usize) -> Vec<Vec<f32>> {
    let bin_count = frame_size / 2 + 1;
    let nyquist = f64::from(sample_rate) / 2.0;
    let mel_max = hz_to_mel(nyquist);
    let mel_points: Vec<f64> = (0..=bands + 1)
        .map(|i| mel_max * i as f64 / (bands + 1) as f64)
        .collect();
    let hz_points: Vec<f64> = mel_points.iter().map(|mel| mel_to_hz(*mel)).collect();
    let bin_points: Vec<usize> = hz_points
        .iter()
        .map(|hz| {
            ((hz * frame_size as f64 / f64::from(sample_rate)).round() as usize).min(bin_count - 1)
        })
        .collect();

    (0..bands)
        .map(|band| {
            let mut filter = vec![0.0_f32; bin_count];
            let (left, center, right) =
                (bin_points[band], bin_points[band + 1], bin_points[band + 2]);
            for bin in left..center {
                if center > left {
                    filter[bin] = (bin - left) as f32 / (center - left) as f32;
                }
            }
            for bin in center..right {
                if right > center {
                    filter[bin] = 1.0 - (bin - center) as f32 / (right - center) as f32;
                }
            }
            filter
        })
        .collect()
}

fn hz_to_mel(hz: f64) -> f64 {
    2_595.0 * (1.0 + hz / 700.0).log10()
}

fn mel_to_hz(mel: f64) -> f64 {
    700.0 * (10_f64.powf(mel / 2_595.0) - 1.0)
}

/// 13 MFCCs for one frame via a mel filterbank + DCT-II — a direct O(bands ×
/// coefficients) sum is used rather than a fast DCT, since 26 bands is small enough
/// that it costs nothing measurable.
fn mfcc(magnitudes: &[f32], mel_filters: &[Vec<f32>]) -> [f64; MFCC_COUNT] {
    let log_mel: Vec<f64> = mel_filters
        .iter()
        .map(|filter| {
            let energy: f64 = filter
                .iter()
                .zip(magnitudes.iter())
                .map(|(weight, magnitude)| f64::from(*weight) * f64::from(*magnitude))
                .sum();
            (energy.max(1e-10)).ln()
        })
        .collect();

    let bands = log_mel.len() as f64;
    let mut coefficients = [0.0_f64; MFCC_COUNT];
    for (i, coefficient) in coefficients.iter_mut().enumerate() {
        *coefficient = log_mel
            .iter()
            .enumerate()
            .map(|(band, value)| {
                value * (std::f64::consts::PI / bands * (band as f64 + 0.5) * i as f64).cos()
            })
            .sum();
    }
    coefficients
}

/// 12-bin chroma (pitch-class) profile for one frame, normalized to sum to 1 so
/// louder frames don't dominate the average.
fn chroma(magnitudes: &[f32], sample_rate: u32, frame_size: usize) -> [f64; CHROMA_BINS] {
    let mut bins = [0.0_f64; CHROMA_BINS];
    for (bin, magnitude) in magnitudes.iter().enumerate().skip(1) {
        let freq = bin as f64 * f64::from(sample_rate) / frame_size as f64;
        if freq <= 0.0 {
            continue;
        }
        let midi = 69.0 + 12.0 * (freq / 440.0).log2();
        let pitch_class = (midi.round() as i64).rem_euclid(12) as usize;
        bins[pitch_class] += f64::from(*magnitude);
    }
    let total: f64 = bins.iter().sum();
    if total > 0.0 {
        for bin in &mut bins {
            *bin /= total;
        }
    }
    bins
}

fn aggregate_frames<const N: usize>(frames: &[[f64; N]]) -> Vec<f64> {
    if frames.is_empty() {
        return vec![0.0; N * 2];
    }
    let mut means = [0.0_f64; N];
    for frame in frames {
        for (i, value) in frame.iter().enumerate() {
            means[i] += value;
        }
    }
    for mean in &mut means {
        *mean /= frames.len() as f64;
    }
    let mut variances = [0.0_f64; N];
    for frame in frames {
        for (i, value) in frame.iter().enumerate() {
            variances[i] += (value - means[i]).powi(2);
        }
    }
    for variance in &mut variances {
        *variance /= frames.len() as f64;
    }
    means.into_iter().chain(variances).collect()
}

fn aggregate_chroma(frames: &[[f64; CHROMA_BINS]]) -> Vec<f64> {
    if frames.is_empty() {
        return vec![0.0; CHROMA_BINS];
    }
    let mut mean = [0.0_f64; CHROMA_BINS];
    for frame in frames {
        for (i, value) in frame.iter().enumerate() {
            mean[i] += value;
        }
    }
    for value in &mut mean {
        *value /= frames.len() as f64;
    }
    mean.to_vec()
}

/// Autocorrelates `onset_envelope` over the lag range implied by
/// [`MIN_TEMPO_BPM`]/[`MAX_TEMPO_BPM`] to find the dominant beat period. Returns
/// `(tempo_bpm, danceability)` — danceability is the winning lag's autocorrelation
/// relative to the mean across all evaluated lags (how much more regular the detected
/// beat is than a "typical" lag), a library-internal regularity proxy, not an
/// absolute/calibrated score. Falls back to `(120.0, 0.0)` (a neutral, unremarkable
/// tempo) when there's too little onset data to estimate anything.
fn estimate_tempo(onset_envelope: &[f64], frame_rate: f64) -> (f64, f64) {
    if onset_envelope.len() < 8 || frame_rate <= 0.0 {
        return (120.0, 0.0);
    }
    let min_lag = (frame_rate * 60.0 / MAX_TEMPO_BPM).round().max(1.0) as usize;
    let max_lag = (frame_rate * 60.0 / MIN_TEMPO_BPM).round() as usize;
    let max_lag = max_lag.min(onset_envelope.len().saturating_sub(1));
    if min_lag >= max_lag {
        return (120.0, 0.0);
    }

    let mut best_lag = min_lag;
    let mut best_score = f64::MIN;
    let mut scores = Vec::with_capacity(max_lag - min_lag + 1);
    for lag in min_lag..=max_lag {
        let pairs = onset_envelope.len() - lag;
        if pairs == 0 {
            continue;
        }
        let score: f64 = (0..pairs)
            .map(|i| onset_envelope[i] * onset_envelope[i + lag])
            .sum::<f64>()
            / pairs as f64;
        scores.push(score);
        if score > best_score {
            best_score = score;
            best_lag = lag;
        }
    }
    if scores.is_empty() {
        return (120.0, 0.0);
    }
    let mean_score = scores.iter().sum::<f64>() / scores.len() as f64;
    let danceability = if mean_score > 0.0 {
        (best_score / mean_score - 1.0).max(0.0)
    } else {
        0.0
    };
    let tempo_bpm = frame_rate * 60.0 / best_lag as f64;
    (tempo_bpm.clamp(MIN_TEMPO_BPM, MAX_TEMPO_BPM), danceability)
}

#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct AudioFeatureQueueStatus {
    pub queued: u64,
    pub in_flight: bool,
    pub processed: u64,
    pub failed: u64,
    pub last_error: Option<String>,
}

/// Background analysis queue — mirrors `loudness::LoudnessQueue` exactly (same
/// mpsc-worker/pending-set/status shape), since it's the same "decode once, store a
/// compact result" job pattern.
#[derive(Clone)]
pub struct AudioFeatureQueue {
    inner: Arc<Inner>,
}

struct Inner {
    sender: mpsc::UnboundedSender<Job>,
    queued: AtomicU64,
    in_flight: AtomicBool,
    processed: AtomicU64,
    failed: AtomicU64,
    last_error: Mutex<Option<String>>,
    pending: StdMutex<HashSet<String>>,
}

#[derive(Clone)]
struct Job {
    content_hash: String,
    path: PathBuf,
}

/// Callback invoked with the analyzed features on success — kept generic (rather than
/// depending on `aro_sync_store::HubStore` directly, as `loudness::LoudnessQueue`
/// does) so this crate doesn't need a `HubStore` import solely for this queue; the
/// caller (`aro-server`) supplies the store write.
pub type AudioFeatureSink =
    Arc<dyn Fn(&str, i64, &AudioFeatures) -> anyhow::Result<()> + Send + Sync>;
pub type AudioFeatureFailureSink = Arc<dyn Fn(&str, i64, &str) + Send + Sync>;

impl AudioFeatureQueue {
    pub fn start(on_success: AudioFeatureSink, on_failure: AudioFeatureFailureSink) -> Self {
        let (sender, mut receiver) = mpsc::unbounded_channel::<Job>();
        let inner = Arc::new(Inner {
            sender,
            queued: AtomicU64::new(0),
            in_flight: AtomicBool::new(false),
            processed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            last_error: Mutex::new(None),
            pending: StdMutex::new(HashSet::new()),
        });
        let worker = inner.clone();
        tokio::spawn(async move {
            while let Some(job) = receiver.recv().await {
                worker.queued.fetch_sub(1, Ordering::Relaxed);
                worker.in_flight.store(true, Ordering::Relaxed);
                let hash = job.content_hash.clone();
                let path = job.path.clone();
                let analyzed = tokio::task::spawn_blocking(move || analyze_file(&path)).await;
                match analyzed {
                    Ok(Ok(features)) => match on_success(&hash, ALGORITHM_VERSION, &features) {
                        Ok(()) => {
                            worker.processed.fetch_add(1, Ordering::Relaxed);
                        }
                        Err(error) => {
                            record_failure(&worker, &on_failure, &hash, &error.to_string());
                        }
                    },
                    Ok(Err(error)) => {
                        record_failure(&worker, &on_failure, &hash, &error.to_string())
                    }
                    Err(error) => record_failure(&worker, &on_failure, &hash, &error.to_string()),
                }
                worker.pending.lock().expect("pending lock").remove(&hash);
                worker.in_flight.store(false, Ordering::Relaxed);

                // A fresh scan/import can enqueue an entire library at once; decoding
                // + FFT analysis is real, sustained CPU work, and running it
                // back-to-back with zero yield visibly starved request handling on a
                // Raspberry Pi during a full-catalog backlog (observed directly).
                // This pause gives the reactor and other queues room to breathe
                // between jobs without meaningfully slowing a large backlog down
                // (analysis itself takes far longer than 150ms per track).
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            }
        });
        Self { inner }
    }

    pub fn enqueue(&self, content_hash: String, path: PathBuf) {
        let mut pending = self.inner.pending.lock().expect("pending lock");
        if !pending.insert(content_hash.clone()) {
            return;
        }
        self.inner.queued.fetch_add(1, Ordering::Relaxed);
        if self
            .inner
            .sender
            .send(Job {
                content_hash: content_hash.clone(),
                path,
            })
            .is_err()
        {
            self.inner.queued.fetch_sub(1, Ordering::Relaxed);
            pending.remove(&content_hash);
        }
    }

    pub async fn status(&self) -> AudioFeatureQueueStatus {
        AudioFeatureQueueStatus {
            queued: self.inner.queued.load(Ordering::Relaxed),
            in_flight: self.inner.in_flight.load(Ordering::Relaxed),
            processed: self.inner.processed.load(Ordering::Relaxed),
            failed: self.inner.failed.load(Ordering::Relaxed),
            last_error: self.inner.last_error.lock().await.clone(),
        }
    }
}

fn record_failure(
    inner: &Inner,
    on_failure: &AudioFeatureFailureSink,
    content_hash: &str,
    message: &str,
) {
    inner.failed.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut last_error) = inner.last_error.try_lock() {
        *last_error = Some(message.to_string());
    }
    on_failure(content_hash, ALGORITHM_VERSION, message);
    tracing::warn!(
        content_hash,
        error = message,
        "audio feature analysis failed"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(samples: usize, sample_rate: u32, freq: f32, amplitude: f32) -> Vec<f32> {
        (0..samples)
            .map(|i| {
                let t = i as f32 / sample_rate as f32;
                (t * freq * std::f32::consts::TAU).sin() * amplitude
            })
            .collect()
    }

    #[test]
    fn energy_reflects_amplitude() {
        let sample_rate: u32 = 44_100;
        let loud = sine(sample_rate as usize * 3, sample_rate, 440.0, 0.8);
        let quiet = sine(sample_rate as usize * 3, sample_rate, 440.0, 0.1);

        let loud_features = analyze_samples(&loud, sample_rate).unwrap();
        let quiet_features = analyze_samples(&quiet, sample_rate).unwrap();

        assert!(loud_features.energy_mean > quiet_features.energy_mean);
    }

    #[test]
    fn brightness_reflects_frequency() {
        let sample_rate: u32 = 44_100;
        let low = sine(sample_rate as usize * 3, sample_rate, 110.0, 0.5);
        let high = sine(sample_rate as usize * 3, sample_rate, 6_000.0, 0.5);

        let low_features = analyze_samples(&low, sample_rate).unwrap();
        let high_features = analyze_samples(&high, sample_rate).unwrap();

        assert!(high_features.brightness > low_features.brightness);
    }

    #[test]
    fn chroma_peaks_at_the_played_pitch_class() {
        // A440 is pitch class 9 (A) — 69 + 12*log2(440/440) = 69 -> A.
        let sample_rate: u32 = 44_100;
        let a440 = sine(sample_rate as usize * 3, sample_rate, 440.0, 0.5);

        let features = analyze_samples(&a440, sample_rate).unwrap();

        let (max_index, _) = features
            .chroma
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .unwrap();
        assert_eq!(max_index, 9, "{:?}", features.chroma);
    }

    #[test]
    fn tempo_recovers_a_clicktrack_bpm() {
        let sample_rate = 44_100_u32;
        let bpm = 120.0;
        let beat_interval = (60.0 / bpm * sample_rate as f64) as usize;
        let duration_samples = sample_rate as usize * 20;
        let mut samples = vec![0.0_f32; duration_samples];
        let mut position = 0;
        while position + 200 < samples.len() {
            for (offset, sample) in samples[position..position + 200].iter_mut().enumerate() {
                // A short burst of a mid-range tone approximates a percussive click.
                let t = offset as f32 / sample_rate as f32;
                *sample =
                    (t * 2_000.0 * std::f32::consts::TAU).sin() * (1.0 - offset as f32 / 200.0);
            }
            position += beat_interval;
        }

        let features = analyze_samples(&samples, sample_rate).unwrap();
        assert!(
            (features.tempo_bpm - bpm).abs() < 6.0,
            "expected close to {bpm} BPM, got {}",
            features.tempo_bpm
        );
    }

    #[test]
    fn vector_has_a_fixed_length() {
        let sample_rate: u32 = 44_100;
        let tone = sine(sample_rate as usize * 3, sample_rate, 440.0, 0.5);
        let features = analyze_samples(&tone, sample_rate).unwrap();
        assert_eq!(features.vector().len(), 5 + 26 + 12);
    }

    #[test]
    fn too_short_a_clip_is_a_typed_error_not_a_panic() {
        let sample_rate: u32 = 44_100;
        let tiny = vec![0.0_f32; 10];
        assert!(matches!(
            analyze_samples(&tiny, sample_rate),
            Err(Error::TooShort)
        ));
    }
}
