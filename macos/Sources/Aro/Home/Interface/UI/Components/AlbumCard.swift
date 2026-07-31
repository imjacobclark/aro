import AroCommon
import SwiftUI

/// An artwork-forward tile for playlists that DO represent one real-world thing (an
/// artist, an album, a year) — a small mosaic of the playlist's own album art,
/// diversified by album so it doesn't show the same cover four times over, or a
/// single cover when there aren't enough distinct albums to fill a mosaic. No card
/// chrome of its own — the artwork and title/artist text sit directly on the page
/// background, matching how a real album cover reads on its own rather than boxed
/// inside a grey card.
struct AlbumCard: View {
    let playlist: ServerGeneratedPlaylist
    let songs: [Song]

    private let artworkSide: CGFloat = HomeCardMetrics.artworkSide

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            realArtworkMosaic
            VStack(alignment: .leading, spacing: 3) {
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
        .frame(width: artworkSide, height: HomeCardMetrics.height, alignment: .top)
    }

    /// A playlist grouped by a single real album (`.recentlyPlayedAlbum`, `.lostAlbum`)
    /// has exactly one cover to show — a 4-tile mosaic would just repeat that same
    /// cover four times over, which reads as a rendering bug, not variety. The mosaic
    /// only makes sense for playlists that genuinely span multiple albums (currently
    /// `.hitsByYear`).
    private var realArtworkMosaic: some View {
        let distinctAlbumCount = Set(songs.compactMap(\.album)).count
        // Same reasoning as `representativeArtwork`: build the mosaic out of tracks
        // that actually have art, so a few untagged files in an otherwise-illustrated
        // playlist don't punch placeholder-disc holes in the grid. Falls back to the
        // full list when too few tracks have art to fill a mosaic at all, in which
        // case the `count >= 4` check below sends us down the single-cover path.
        let illustrated = songs.filter { $0.artworkData != nil }
        let tiles = (illustrated.count >= 4 ? illustrated : songs).diverseByAlbum(count: 4)
        return Group {
            if distinctAlbumCount > 1, tiles.count >= 4 {
                let tileSide = (artworkSide - 3) / 2
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
                    data: representativeArtwork,
                    maxDimension: artworkSide
                )
                .frame(width: artworkSide, height: artworkSide)
            }
        }
    }

    /// The first track that actually carries embedded art, rather than simply the
    /// first track. Embedded artwork is per-file, so a rip where (say) only the
    /// opening track was tagged with the cover would otherwise render the whole
    /// album as the "no artwork" placeholder purely because `songs.first` happened
    /// to be one of the untagged files — even though the art is right there on a
    /// sibling track.
    private var representativeArtwork: Data? {
        songs.first { $0.artworkData != nil }?.artworkData
    }

    private func artworkTile(_ song: Song, side: CGFloat) -> some View {
        AlbumArtworkView(data: song.artworkData, maxDimension: side)
            .frame(width: side, height: side)
    }
}
