import AppKit
import ImageIO
import SwiftUI

struct AlbumArtworkView: View {
    let data: Data?
    /// The largest point size this artwork will actually be rendered at
    /// (e.g. the view's `.frame` width). Used to downsample the decoded
    /// image so a large embedded piece of art isn't decoded at full
    /// resolution just to be shown in a small thumbnail.
    var maxDimension: CGFloat = 256

    var body: some View {
        Group {
            if let image = ArtworkImageCache.image(for: data, maxDimension: maxDimension) {
                // `Color.clear` (not the image) is what's measured here: it accepts
                // whatever size the caller's `.frame()` proposes, the overlaid image
                // fills that box — overflowing on its short axis, since a non-square
                // cover scaled to *fill* a square must — and `.clipped()` then cuts
                // that overflow off at `Color.clear`'s bounds.
                //
                // Applying `.scaledToFill().clipped()` directly to the image instead
                // does nothing: `scaledToFill` reports the *overflowing* size as the
                // image view's own bounds, so the clip is a no-op against them, and
                // the artwork spills over whatever is laid out below it (observed
                // with non-square covers overlapping their own title/artist text).
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(
                        gradient: AroTheme.orbitGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(0.28)

                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .accessibilityLabel(data == nil ? "No album artwork" : "Album artwork")
    }
}

@MainActor
private enum ArtworkImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()

    static func image(for data: Data?, maxDimension: CGFloat) -> NSImage? {
        guard let data else { return nil }
        let key = "\(data.hashValue)_\(Int(maxDimension))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = downsampledImage(
            data: data,
            maxDimension: maxDimension
        ) else {
            return nil
        }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Decodes directly to a thumbnail no larger than `maxDimension` (in
    /// Retina pixels), rather than decoding the source image at full
    /// resolution and letting SwiftUI scale it down for display.
    private static func downsampledImage(
        data: Data,
        maxDimension: CGFloat
    ) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension * scale,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return NSImage(data: data)
        }
        // `NSSize` is in *points*, but the thumbnail was rendered at
        // `maxDimension * scale` *pixels* — passing the pixel counts straight
        // through would declare an intrinsic size `scale`× too large on a Retina
        // display. Dividing back out keeps the image's declared size equal to the
        // point size it's meant to occupy, while retaining the full-resolution
        // backing store.
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(
                width: CGFloat(thumbnail.width) / scale,
                height: CGFloat(thumbnail.height) / scale
            )
        )
    }
}
