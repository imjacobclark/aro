//! Background BS.1770 loudness analysis for remotely playable tracks.

use aro_sync_store::HubStore;
use bs1770::{ChannelLoudnessMeter, gated_mean, reduce_stereo};
use serde::Serialize;
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
use uuid::Uuid;

pub const ALGORITHM_VERSION: i64 = 2;

#[derive(Debug, Clone)]
pub struct LoudnessResult {
    pub integrated_lufs: f64,
    pub peak_amplitude: f64,
}

#[derive(Debug, Error)]
pub enum Error {
    #[error("unsupported audio format for loudness analysis: {0}")]
    UnsupportedFormat(String),
    #[error("no audio track found in file")]
    NoAudioTrack,
    #[error("only mono and stereo loudness analysis are currently supported")]
    UnsupportedChannels,
    #[error("decoding produced too little audio for an integrated measurement")]
    TooShort,
    #[error("decoding produced an invalid loudness measurement")]
    InvalidMeasurement,
    #[error(transparent)]
    Symphonia(#[from] symphonia::core::errors::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub fn analyze_file(path: &Path) -> Result<LoudnessResult, Error> {
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

    let mut meters: Option<Vec<ChannelLoudnessMeter>> = None;
    let mut peak_amplitude = 0.0_f32;
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
        let channel_count = spec.channels.count();
        if !(1..=2).contains(&channel_count) {
            return Err(Error::UnsupportedChannels);
        }
        let active_meters = meters.get_or_insert_with(|| {
            (0..channel_count)
                .map(|_| ChannelLoudnessMeter::new(spec.rate))
                .collect()
        });
        if active_meters.len() != channel_count {
            return Err(Error::UnsupportedChannels);
        }

        let mut samples = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        samples.copy_interleaved_ref(decoded);
        let interleaved = samples.samples();
        // The index is the channel's offset into the interleaved frame as well as the
        // meter to feed, so it is genuinely arithmetic rather than mere addressing.
        #[allow(clippy::needless_range_loop)]
        for channel in 0..channel_count {
            let channel_samples = interleaved
                .iter()
                .skip(channel)
                .step_by(channel_count)
                .copied()
                .inspect(|sample| {
                    peak_amplitude = peak_amplitude.max(sample.abs());
                });
            active_meters[channel].push(channel_samples);
        }
    }

    let meters = meters.ok_or(Error::TooShort)?;
    let windows = meters
        .into_iter()
        .map(ChannelLoudnessMeter::into_100ms_windows)
        .collect::<Vec<_>>();
    let combined = match windows.as_slice() {
        [mono] => reduce_stereo(mono.as_ref(), mono.as_ref()),
        [left, right] => reduce_stereo(left.as_ref(), right.as_ref()),
        _ => return Err(Error::UnsupportedChannels),
    };
    if combined.len() < 4 {
        return Err(Error::TooShort);
    }
    let integrated_lufs = f64::from(gated_mean(combined.as_ref()).loudness_lkfs());
    if !integrated_lufs.is_finite() || !peak_amplitude.is_finite() {
        return Err(Error::InvalidMeasurement);
    }
    Ok(LoudnessResult {
        integrated_lufs,
        peak_amplitude: f64::from(peak_amplitude),
    })
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct LoudnessQueueStatus {
    pub queued: u64,
    pub in_flight: bool,
    pub processed: u64,
    pub failed: u64,
    pub last_error: Option<String>,
}

#[derive(Clone)]
pub struct LoudnessQueue {
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

impl LoudnessQueue {
    pub fn start(store: HubStore, hub_id: Uuid) -> Self {
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
                    Ok(Ok(result)) => {
                        match store.put_loudness_analysis(
                            &hash,
                            ALGORITHM_VERSION,
                            result.integrated_lufs,
                            result.peak_amplitude,
                            hub_id,
                        ) {
                            Ok(()) => {
                                worker.processed.fetch_add(1, Ordering::Relaxed);
                                store.clear_loudness_failure(&hash, ALGORITHM_VERSION).ok();
                            }
                            Err(error) => {
                                record_failure(&worker, &store, &hash, &error.to_string());
                            }
                        }
                    }
                    Ok(Err(error)) => {
                        record_failure(&worker, &store, &hash, &error.to_string());
                    }
                    Err(error) => {
                        record_failure(&worker, &store, &hash, &error.to_string());
                    }
                }
                worker.pending.lock().expect("pending lock").remove(&hash);
                worker.in_flight.store(false, Ordering::Relaxed);
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

    pub async fn status(&self) -> LoudnessQueueStatus {
        LoudnessQueueStatus {
            queued: self.inner.queued.load(Ordering::Relaxed),
            in_flight: self.inner.in_flight.load(Ordering::Relaxed),
            processed: self.inner.processed.load(Ordering::Relaxed),
            failed: self.inner.failed.load(Ordering::Relaxed),
            last_error: self.inner.last_error.lock().await.clone(),
        }
    }
}

fn record_failure(inner: &Inner, store: &HubStore, content_hash: &str, message: &str) {
    inner.failed.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut last_error) = inner.last_error.try_lock() {
        *last_error = Some(message.to_string());
    }
    store
        .record_loudness_failure(content_hash, ALGORITHM_VERSION, message)
        .ok();
    tracing::warn!(content_hash, error = message, "loudness analysis failed");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_sine_wav(path: &Path, channels: u16, amplitude: f32) {
        let sample_rate = 44_100_u32;
        let frame_count = sample_rate * 5;
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
            let sample = (t * 440.0 * std::f32::consts::TAU).sin() * amplitude;
            let value = (sample * i16::MAX as f32) as i16;
            for _ in 0..channels {
                wav.extend_from_slice(&value.to_le_bytes());
            }
        }
        std::fs::write(path, wav).unwrap();
    }

    #[test]
    fn analyzes_stereo_sine_loudness_and_peak() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tone.wav");
        write_sine_wav(&path, 2, 0.5);

        let result = analyze_file(&path).expect("tone should analyze");

        assert!(result.integrated_lufs.is_finite());
        assert!(
            (result.peak_amplitude - 0.5).abs() < 0.01,
            "unexpected peak {}",
            result.peak_amplitude
        );
        assert!(
            (-7.0..=-5.0).contains(&result.integrated_lufs),
            "unexpected loudness {}",
            result.integrated_lufs
        );
    }

    #[test]
    fn rejects_more_than_two_channels() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("surround.wav");
        write_sine_wav(&path, 3, 0.25);

        assert!(matches!(
            analyze_file(&path),
            Err(Error::UnsupportedChannels)
        ));
    }
}
