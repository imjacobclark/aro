import AroCommon
import SwiftUI

/// Starting a station from a seed song, in one place.
///
/// Radio is offered from several surfaces — a track row, Home's mixes, an artist — and each
/// one wants the same four steps: take the seed's content hash, ask the hub for a station,
/// resolve the hashes it returns against the library we can actually play, and start on the
/// first of them. That had been written out separately per surface, which is how the artist
/// page ended up with a "More Like This" shelf and no way to *start* anything.
///
/// Silent when there is nothing to play. A seed with no content hash has never reached the
/// hub, an unreachable hub returns nothing, and a station whose tracks aren't in this
/// library resolves to an empty queue — none of which is an error worth interrupting
/// someone for, and all of which simply mean there is no station to start.
@MainActor
enum RadioStation {
    static func start(
        seededBy song: Song,
        in library: [Song],
        loadRadio: (String) async -> ServerGeneratedPlaylist?,
        playback: PlaybackController
    ) async {
        guard let contentHash = song.contentHash,
              let station = await loadRadio(contentHash) else { return }
        let queue = SongLibrary.resolving(station.contentHashes, in: library)
        guard let first = queue.first else { return }
        playback.playStation(song: first, queue: queue)
    }
}
