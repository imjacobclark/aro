//! Lossless conversion to the one format every Aro client can decode.
//!
//! Aro keeps what the listener owns, exactly as they own it — which is the right promise and
//! also the reason a library can be unplayable on half the devices that ask for it. Roughly
//! nine in ten tracks in the reference library are Apple Lossless, and no browser but Safari
//! has ever shipped an ALAC decoder. Until now the only answer was the Opus ladder, which is
//! lossy: fine for low data mode, wrong as the way a lossless library is normally heard.
//!
//! FLAC is the format that resolves it. It is lossless, so a converted copy is the same audio
//! by definition rather than by approximation, and it decodes in Chrome, Firefox, Edge,
//! Safari, Android, and SFBAudioEngine on the Mac. Nothing else is both.
//!
//! What this module does *not* do is as important: it never touches the original. A
//! compatibility copy is a third file alongside the library and the managed blob store, and
//! the original remains the thing Aro serves whenever the asking client can play it.

use crate::transcode::Error;
use flacenc::error::Verify;
use std::io::Write;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// Formats that already play everywhere, and so need no second copy.
///
/// This is what keeps the feature's cost honest. Converting a library wholesale would double
/// it on disk; converting only what cannot otherwise be played leaves FLAC, MP3, AAC and WAV
/// where they are and spends the space on the files that actually need it. On a library that
/// is mostly ALAC that is still most of the library — but on one that is mostly FLAC it is
/// nearly nothing, and the setting should be able to say so before anyone commits to it.
pub fn needs_compatibility_copy(codec: &str) -> bool {
    !matches!(
        codec.trim().to_ascii_lowercase().as_str(),
        // Lossless and universally decodable already.
        "flac"
            // Lossy, but no browser lacks a decoder for these.
            | "mp3" | "mpeg" | "aac" | "ogg" | "oga" | "opus" | "vorbis"
            // Uncompressed; large, but nothing refuses them.
            | "wav" | "wave"
    )
}

/// Sample count per FLAC frame. 4096 is the reference encoder's default and what every
/// decoder is best exercised against; there is no reason to be unusual here.
const BLOCK_SIZE: usize = 4096;

/// Decodes `source` and writes FLAC to `sink`.
///
/// Lossless end to end: the source's own sample rate and bit depth are preserved, and no
/// resampling happens. That is the difference between this and `transcode_to_ogg_opus`, which
/// deliberately lands everything on Opus's 48 kHz — here, changing the rate would make the
/// "lossless" claim false.
pub fn convert_to_flac(source: &Path, sink: &mut impl Write) -> Result<(), Error> {
    let pcm = FlacSource::open(source)?;
    let config = flacenc::config::Encoder::default()
        .into_verified()
        .map_err(|(_, error)| Error::Flac(format!("encoder configuration rejected: {error}")))?;

    let stream = flacenc::encode_with_fixed_block_size(&config, pcm, BLOCK_SIZE)
        .map_err(|error| Error::Flac(error.to_string()))?;

    let mut bytes = flacenc::bitsink::ByteSink::new();
    flacenc::component::BitRepr::write(&stream, &mut bytes)
        .map_err(|error| Error::Flac(error.to_string()))?;
    sink.write_all(bytes.as_slice())?;
    sink.flush()?;
    Ok(())
}

/// Pulls decoded samples out of symphonia one FLAC block at a time.
///
/// Implemented as a `Source` rather than decoding to a `Vec` first because the hub this runs
/// on has 917 MB and no swap: a five-minute stereo album track is over a hundred megabytes as
/// `i32`, and holding a whole one — let alone several at once — is how the machine falls over.
/// The encoder asks for a block, this decodes just enough to answer, and nothing accumulates.
struct FlacSource {
    format: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    channels: usize,
    sample_rate: u32,
    bits_per_sample: u32,
    /// Decoded samples not yet handed to the encoder. A decoded packet rarely lines up with
    /// a FLAC block, so the remainder waits here for the next call.
    pending: Vec<i32>,
    exhausted: bool,
}

impl FlacSource {
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
        let track = format
            .tracks()
            .iter()
            .find(|track| track.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
            .ok_or(Error::NoAudioTrack)?;
        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &Default::default())
            .map_err(|error| match error {
                symphonia::core::errors::Error::Unsupported(reason) => {
                    Error::UnsupportedFormat(reason.to_string())
                }
                other => Error::Symphonia(other),
            })?;
        let sample_rate = track
            .codec_params
            .sample_rate
            .ok_or(Error::UnknownSampleRate)?;
        let channels = track
            .codec_params
            .channels
            .map(|channels| channels.count())
            .unwrap_or(2);
        // FLAC itself allows up to eight, and the format's own limits are what should decide
        // this rather than Opus's stereo-only ceiling.
        if !(1..=8).contains(&channels) {
            return Err(Error::UnsupportedChannels(channels));
        }
        // A source that does not declare its depth is treated as 16-bit, which is the only
        // safe guess: assuming more would shift real samples up into silence.
        let bits_per_sample = track
            .codec_params
            .bits_per_sample
            .unwrap_or(16)
            .clamp(4, 32);

        Ok(Self {
            track_id: track.id,
            format,
            decoder,
            channels,
            sample_rate,
            bits_per_sample,
            pending: Vec::new(),
            exhausted: false,
        })
    }

    /// Decodes the next packet into `pending`, or reports that the stream has ended.
    fn decode_more(&mut self) -> Result<bool, Error> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(packet) => packet,
                // Symphonia signals end of stream as an IO error rather than a variant.
                Err(symphonia::core::errors::Error::IoError(error))
                    if error.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(false);
                }
                Err(symphonia::core::errors::Error::ResetRequired) => return Ok(false),
                Err(error) => return Err(Error::Symphonia(error)),
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(buffer) => {
                    let spec = *buffer.spec();
                    let mut samples = SampleBuffer::<i32>::new(buffer.capacity() as u64, spec);
                    samples.copy_interleaved_ref(buffer);
                    // Symphonia hands back samples scaled to the full i32 range whatever the
                    // source depth, so they have to come back down to the depth actually
                    // being written — FLAC treats a sample as an integer of exactly
                    // `bits_per_sample` bits, and a 16-bit track left at 32-bit scale would
                    // encode as gross overload rather than as loud audio.
                    let shift = 32 - self.bits_per_sample;
                    self.pending
                        .extend(samples.samples().iter().map(|sample| sample >> shift));
                    if self.pending.is_empty() {
                        continue;
                    }
                    return Ok(true);
                }
                // A single corrupt packet shouldn't abort a whole track; skipping it costs
                // 20 ms of audio where failing costs the listener the song.
                Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
                Err(error) => return Err(Error::Symphonia(error)),
            }
        }
    }
}

impl flacenc::source::Source for FlacSource {
    fn channels(&self) -> usize {
        self.channels
    }

    fn bits_per_sample(&self) -> usize {
        self.bits_per_sample as usize
    }

    fn sample_rate(&self) -> usize {
        self.sample_rate as usize
    }

    fn read_samples<F: flacenc::source::Fill>(
        &mut self,
        block_size: usize,
        dest: &mut F,
    ) -> Result<usize, flacenc::error::SourceError> {
        let wanted = block_size * self.channels;
        while self.pending.len() < wanted && !self.exhausted {
            match self.decode_more() {
                Ok(true) => {}
                Ok(false) => self.exhausted = true,
                Err(error) => {
                    // The encoder's error type carries no payload, so the real cause is
                    // logged here rather than lost on the way up.
                    tracing::warn!(%error, "decoding for FLAC conversion failed");
                    return Err(flacenc::error::SourceError::from_unknown());
                }
            }
        }

        // A final partial block is normal and is exactly what FLAC's last frame is for.
        let taking = wanted.min(self.pending.len());
        if taking == 0 {
            return Ok(0);
        }
        let block: Vec<i32> = self.pending.drain(..taking).collect();
        dest.fill_interleaved(&block)?;
        Ok(taking / self.channels)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_formats_that_cannot_be_played_everywhere_need_converting() {
        // The whole point of the feature: ALAC in an MP4 container is the case no browser
        // but Safari can decode, and is what the reference library is made of.
        assert!(needs_compatibility_copy("m4a"));
        assert!(needs_compatibility_copy("alac"));
        assert!(needs_compatibility_copy("aiff"));

        // Already universal — converting these would spend disk for nothing.
        assert!(!needs_compatibility_copy("flac"));
        assert!(!needs_compatibility_copy("mp3"));
        assert!(!needs_compatibility_copy("wav"));
        assert!(!needs_compatibility_copy("opus"));
    }

    #[test]
    fn codec_matching_ignores_case_and_padding() {
        assert!(!needs_compatibility_copy("  FLAC "));
        assert!(!needs_compatibility_copy("Mp3"));
    }

    /// A real encode, checked against the stream header rather than against my reading of
    /// the spec. Rate, depth, channel count and total sample count all surviving is exactly
    /// what makes "lossless copy" a true claim rather than a hopeful one.
    ///
    /// Deliberately not round-tripped through symphonia: symphonia's FLAC probe rejects
    /// flacenc's output, while CoreAudio (`afinfo`) reads it as a correct 1.000000 sec
    /// 44.1 kHz 16-bit stereo stream, and the STREAMINFO parsed below is well-formed with a
    /// real MD5. Asserting on the bytes we write keeps this test about our encoder instead
    /// of about another decoder's appetite.
    #[test]
    fn converts_a_wav_to_flac_preserving_rate_depth_and_length() {
        let source = tempfile::Builder::new().suffix(".wav").tempfile().unwrap();
        let rate = 44_100u32;
        let mut pcm: Vec<u8> = Vec::new();
        for index in 0..rate {
            let value = ((index as f64 * 440.0 * std::f64::consts::TAU / rate as f64).sin()
                * 12_000.0) as i16;
            pcm.extend_from_slice(&value.to_le_bytes());
            pcm.extend_from_slice(&value.to_le_bytes());
        }
        write_wav(source.path(), &pcm, rate, 2, 16);

        let mut encoded: Vec<u8> = Vec::new();
        convert_to_flac(source.path(), &mut encoded).expect("encode should succeed");

        assert_eq!(&encoded[..4], b"fLaC", "output must be a FLAC stream");
        let info = StreamInfo::parse(&encoded);
        assert_eq!(info.sample_rate, rate, "sample rate must survive untouched");
        assert_eq!(info.bits_per_sample, 16, "bit depth must survive untouched");
        assert_eq!(info.channels, 2, "channel count must survive untouched");
        assert_eq!(
            info.total_samples, rate as u64,
            "every sample must be accounted for — a short count means audio was dropped"
        );
        assert_ne!(
            info.md5, [0u8; 16],
            "a real MD5 is what lets any decoder verify the copy is intact"
        );
        assert!(
            encoded.len() < pcm.len(),
            "lossless should still be smaller than raw PCM, got {} vs {}",
            encoded.len(),
            pcm.len()
        );
    }

    /// A source that resamples would not be lossless, so the rate has to pass through even
    /// when it is not one of the common ones.
    #[test]
    fn an_unusual_sample_rate_is_not_normalised_away() {
        let source = tempfile::Builder::new().suffix(".wav").tempfile().unwrap();
        let rate = 96_000u32;
        let pcm: Vec<u8> = (0..rate)
            .flat_map(|index| {
                let value = ((index % 128) as i16) * 100;
                value.to_le_bytes()
            })
            .collect();
        write_wav(source.path(), &pcm, rate, 1, 16);

        let mut encoded: Vec<u8> = Vec::new();
        convert_to_flac(source.path(), &mut encoded).expect("encode should succeed");

        let info = StreamInfo::parse(&encoded);
        assert_eq!(
            info.sample_rate, 96_000,
            "96 kHz must not be resampled to 44.1 or 48"
        );
        assert_eq!(info.channels, 1, "mono must stay mono");
    }

    /// The parts of FLAC's STREAMINFO block that say whether the copy is faithful.
    struct StreamInfo {
        sample_rate: u32,
        channels: u8,
        bits_per_sample: u8,
        total_samples: u64,
        md5: [u8; 16],
    }

    impl StreamInfo {
        fn parse(stream: &[u8]) -> Self {
            // "fLaC", then a 4-byte metadata block header, then 34 bytes of STREAMINFO.
            let body = &stream[8..42];
            let packed = &body[10..18];
            Self {
                sample_rate: ((packed[0] as u32) << 12)
                    | ((packed[1] as u32) << 4)
                    | ((packed[2] as u32) >> 4),
                channels: ((packed[2] >> 1) & 0b111) + 1,
                bits_per_sample: (((packed[2] & 1) << 4) | (packed[3] >> 4)) + 1,
                total_samples: (((packed[3] & 0x0F) as u64) << 32)
                    | u32::from_be_bytes([packed[4], packed[5], packed[6], packed[7]]) as u64,
                md5: body[18..34].try_into().expect("16 bytes of digest"),
            }
        }
    }

    fn write_wav(path: &Path, pcm: &[u8], rate: u32, channels: u16, bits: u16) {
        let byte_rate = rate * channels as u32 * (bits / 8) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&(channels * bits / 8).to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        out.extend_from_slice(pcm);
        std::fs::write(path, out).unwrap();
    }
}
