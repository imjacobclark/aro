import AroCommon

import SwiftUI

/// The floating "now playing" panel: album artwork when the current song
/// has any, otherwise the ambient wave visualizer, followed by track /
/// artist / album text. Kept as a pure function of its inputs, mirroring
/// ``GradientWaveVisualizer``, so it stays easy to preview and reason about
/// independent of `PlaybackController`.
struct NowPlayingArtworkPanel: View {
    let song: Song?
    let spectrum: [Double]
    let isPlaying: Bool

    private let panelWidth: CGFloat = 230

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .frame(width: panelWidth, height: panelWidth)
                .clipped()

            textBlock
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let artworkData = song?.artworkData {
            AlbumArtworkView(data: artworkData, maxDimension: panelWidth)
        } else {
            GradientWaveVisualizer(spectrum: spectrum, isPlaying: isPlaying)
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarqueeText(song?.title ?? "Not Playing")
                .id(song?.id)
                .frame(height: 18)
                .accessibilityLabel(song?.title ?? "Not Playing")

            Text(song?.artist ?? "Choose a song to begin")
                .font(AroFont.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(song?.album ?? ArtistLibrary.unknownAlbum)
                .font(AroFont.caption)
                .foregroundStyle(.secondary.opacity(0.8))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
