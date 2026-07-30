import AroCommon
import SwiftUI

/// Full track list for one generated playlist — a thin wrapper around the existing
/// `SongTableView` (used as-is: nothing in its body depends on real folder identity),
/// plus a back button since `HomeView` owns its own local grid/detail navigation state
/// rather than pushing onto a `NavigationStack`.
struct PlaylistDetailView: View {
    let playlist: ServerGeneratedPlaylist
    let songs: [Song]
    let playback: PlaybackController
    let mediaCache: MediaCacheController
    let usesStreamOnlyIcon: Bool
    let storesLibraryCopy: Bool
    let removeSong: (Song) async throws -> Void
    let syncTrackData: (Song) async -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                Label("Home", systemImage: "chevron.left")
                    .font(AroFont.textStyle(.subheadline, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            SongTableView(
                title: playlist.title,
                songs: songs,
                scanState: .idle,
                hasWatchedFolders: true,
                playback: playback,
                mediaCache: mediaCache,
                usesStreamOnlyIcon: usesStreamOnlyIcon,
                storesLibraryCopy: storesLibraryCopy,
                removeSong: removeSong,
                syncTrackData: syncTrackData
            )
        }
    }
}
