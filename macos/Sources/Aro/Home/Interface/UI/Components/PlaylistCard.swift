import AroCommon
import SwiftUI

/// A "Made for You" grid tile: a small artwork mosaic (or single tile, for a playlist
/// with fewer than 4 songs) plus title/subtitle, styled with the same card chrome as
/// `StatCard` (`.statsSurface()`) for visual consistency with Stats/Library Health.
struct PlaylistCard: View {
    let playlist: ServerGeneratedPlaylist
    let songs: [Song]

    private let artworkSide: CGFloat = 146

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artworkMosaic
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(AroFont.textStyle(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(AroFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsSurface()
    }

    private var artworkMosaic: some View {
        let tiles = Array(songs.prefix(4))
        let tileSide = (artworkSide - 3) / 2
        return Group {
            if tiles.count >= 4 {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        artworkTile(tiles[0], side: tileSide)
                        artworkTile(tiles[1], side: tileSide)
                    }
                    GridRow {
                        artworkTile(tiles[2], side: tileSide)
                        artworkTile(tiles[3], side: tileSide)
                    }
                }
                .frame(width: artworkSide, height: artworkSide)
            } else {
                AlbumArtworkView(
                    data: tiles.first?.artworkData,
                    maxDimension: artworkSide
                )
                .frame(width: artworkSide, height: artworkSide)
            }
        }
    }

    private func artworkTile(_ song: Song, side: CGFloat) -> some View {
        AlbumArtworkView(data: song.artworkData, maxDimension: side)
            .frame(width: side, height: side)
    }
}
