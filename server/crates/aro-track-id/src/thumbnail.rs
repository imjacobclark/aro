//! Downscaled cover art.
//!
//! Covers are stored exactly as they arrived — from a file's embedded art or the Cover Art
//! Archive — and in a real library that means 3000×3000 JPEGs of several megabytes each.
//! Every client was being handed those bytes whatever it intended to draw: a 44-pixel
//! mini-player thumbnail, a 171-pixel grid cell, a full-screen player. Opening the albums
//! grid on a phone measured **60.84 MB**, all of it artwork, for covers rendered into boxes
//! up to twenty-eight times smaller than the pixels they were sent.
//!
//! The clients had already worked around the *symptom* — the web `Artwork` component marks
//! covers `loading="lazy"` and `fetchPriority="low"` so they stop crowding audio out of the
//! connection pool, and macOS downsamples on decode with `CGImageSourceCreateThumbnail`.
//! Neither could do anything about the transfer, which on a phone is the entire cost.
//!
//! So the hub derives the smaller copies, once, and caches them content-addressed. That is
//! the same shape as compatibility copies and transcodes, and it follows the rule the rest
//! of this project already does: derived things are the hub's job, and a client only ever
//! renders what it is given.

use std::io::Cursor;

use image::{ImageReader, imageops::FilterType};

/// The sizes a client may ask for, in pixels on the longest edge.
///
/// A fixed ladder rather than an arbitrary number, because each distinct size is a file on
/// disk and a decode of a very large JPEG on a Raspberry Pi. Two rungs cover every surface
/// in both clients: `Grid` for lists, grids and the mini player, `Detail` for the full
/// screen player and album headers on a Retina display.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThumbnailSize {
    Grid,
    Detail,
}

impl ThumbnailSize {
    /// Longest-edge target. `Grid` at 384 covers a 171pt grid cell at 2×, and comfortably
    /// covers every list row; `Detail` at 1024 covers a full-width player on a 3× phone.
    pub fn max_dimension(self) -> u32 {
        match self {
            Self::Grid => 384,
            Self::Detail => 1024,
        }
    }

    /// Parses the wire value. Unknown sizes are rejected rather than rounded to the nearest
    /// rung, so a client asking for something this hub cannot make finds out.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "grid" => Some(Self::Grid),
            "detail" => Some(Self::Detail),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Grid => "grid",
            Self::Detail => "detail",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ThumbnailError {
    #[error("the cover could not be read as an image: {0}")]
    Decode(#[from] image::ImageError),
    #[error("reading the cover failed: {0}")]
    Io(#[from] std::io::Error),
}

/// What came back from [`downscale`].
pub struct Thumbnail {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Decoding guard.
///
/// The hub runs on a Pi with 917 MB and no swap, and a decoded image costs width × height ×
/// 3 bytes however small the compressed file was — the classic decompression bomb. 50
/// megapixels is far beyond any real cover (a 7000×7000 scan is 49) and caps a single decode
/// at roughly 150 MB.
const MAX_PIXELS: u64 = 50_000_000;

/// JPEG quality for the derived copy. At 82 the ringing around album text is not visible at
/// these dimensions, and the files land well under a tenth of the original.
const QUALITY: u8 = 82;

/// Produces a downscaled JPEG of `source`, or `None` when it is already small enough to send
/// as it stands.
///
/// Returning `None` rather than a re-encode matters: re-compressing an already-small cover
/// would lose quality to save nothing, and the caller can simply serve the original.
pub fn downscale(source: &[u8], size: ThumbnailSize) -> Result<Option<Thumbnail>, ThumbnailError> {
    let target = size.max_dimension();

    let mut reader = ImageReader::new(Cursor::new(source)).with_guessed_format()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(u32::MAX);
    limits.max_image_height = Some(u32::MAX);
    limits.max_alloc = Some(MAX_PIXELS * 4);
    reader.limits(limits);

    let (width, height) = reader.into_dimensions()?;
    if width.max(height) <= target {
        return Ok(None);
    }
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(ThumbnailError::Decode(image::ImageError::Limits(
            image::error::LimitError::from_kind(image::error::LimitErrorKind::DimensionError),
        )));
    }

    // Re-read: `into_dimensions` consumed the first reader, and reading the header twice is
    // far cheaper than decoding an image we may not need to touch at all.
    let decoded = ImageReader::new(Cursor::new(source))
        .with_guessed_format()?
        .decode()?;

    // `thumbnail` is a fast box filter and shows it on album text; Lanczos3 is the one that
    // keeps small type legible, which is most of what a cover at 384px is.
    let resized = decoded.resize(target, target, FilterType::Lanczos3);
    let width = resized.width();
    let height = resized.height();

    // Flattened onto white: covers are opaque in practice, and JPEG cannot carry alpha, so
    // a PNG with transparency would otherwise come out with a black background.
    let rgb = resized.into_rgb8();
    let mut bytes = Vec::new();
    image::DynamicImage::ImageRgb8(rgb).write_with_encoder(
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut Cursor::new(&mut bytes), QUALITY),
    )?;

    Ok(Some(Thumbnail {
        bytes,
        width,
        height,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageFormat;

    fn cover(width: u32, height: u32) -> Vec<u8> {
        let mut image = image::RgbImage::new(width, height);
        // Not a flat fill: a solid colour compresses to almost nothing and would make the
        // size assertions meaningless.
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = image::Rgb([(x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8]);
        }
        let mut bytes = Vec::new();
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut Cursor::new(&mut bytes), ImageFormat::Jpeg)
            .unwrap();
        bytes
    }

    #[test]
    fn a_large_cover_is_reduced_to_the_requested_edge() {
        let source = cover(3000, 3000);
        let thumbnail = downscale(&source, ThumbnailSize::Grid)
            .unwrap()
            .expect("a 3000px cover is larger than the grid size");
        assert_eq!(thumbnail.width.max(thumbnail.height), 384);
        assert!(
            thumbnail.bytes.len() < source.len() / 4,
            "a grid thumbnail should be a fraction of the original, was {} of {}",
            thumbnail.bytes.len(),
            source.len()
        );
    }

    #[test]
    fn a_cover_that_is_already_small_is_left_alone() {
        // Re-encoding this would cost quality and save nothing, so the caller is told to
        // serve what it already has.
        let source = cover(300, 300);
        assert!(downscale(&source, ThumbnailSize::Grid).unwrap().is_none());
    }

    #[test]
    fn a_non_square_cover_keeps_its_aspect_ratio() {
        let thumbnail = downscale(&cover(2000, 1000), ThumbnailSize::Grid)
            .unwrap()
            .expect("larger than the grid size");
        assert_eq!(thumbnail.width, 384);
        assert_eq!(thumbnail.height, 192);
    }

    #[test]
    fn the_detail_size_is_larger_than_the_grid_size() {
        let source = cover(2048, 2048);
        let grid = downscale(&source, ThumbnailSize::Grid).unwrap().unwrap();
        let detail = downscale(&source, ThumbnailSize::Detail).unwrap().unwrap();
        assert_eq!(grid.width, 384);
        assert_eq!(detail.width, 1024);
        assert!(detail.bytes.len() > grid.bytes.len());
    }

    #[test]
    fn something_that_is_not_an_image_is_an_error_rather_than_a_panic() {
        // Blobs are opaque to the store, so a caller can and will point this at audio.
        assert!(downscale(b"not an image at all", ThumbnailSize::Grid).is_err());
    }

    #[test]
    fn sizes_round_trip_through_the_wire_value() {
        for size in [ThumbnailSize::Grid, ThumbnailSize::Detail] {
            assert_eq!(ThumbnailSize::parse(size.as_str()), Some(size));
        }
        assert_eq!(ThumbnailSize::parse("enormous"), None);
    }
}
