import AroCommon
import SwiftUI

struct AlbumSongList: View {
    let songs: [Song]
    let playback: PlaybackController
    let syncTrackData: (Song) async -> Void

    var body: some View {
        AppKitSongTable(
            songs: songs,
            currentSongID: playback.currentSong?.id,
            downloadedSongIDs: [],
            usesStreamOnlyIcon: false,
            presentation: .album,
            onPlay: { song in
                playback.play(song: song, queue: songs)
            },
            onSyncTrackData: { song in
                await syncTrackData(song)
            },
            onRequestRemoval: nil,
            onStartRadio: nil
        )
        .frame(
            minHeight: max(CGFloat(songs.count) * 35, 35),
            maxHeight: max(CGFloat(songs.count) * 35, 35)
        )
    }
}
