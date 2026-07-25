import AppKit
import SwiftUI

struct AlbumArtworkView: View {
    let data: Data?

    var body: some View {
        Group {
            if let image = ArtworkImageCache.image(for: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        gradient: SonoraTheme.orbitGradient,
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
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()

    static func image(for data: Data?) -> NSImage? {
        guard let data else { return nil }
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
}
