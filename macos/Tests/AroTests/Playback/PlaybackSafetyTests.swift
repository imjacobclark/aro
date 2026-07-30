#if canImport(Testing)
import AroCommon
import Foundation
import Testing
@testable import Aro

@Suite("Playback safety")
@MainActor
struct PlaybackSafetyTests {
    @Test("Only the downloaded song reaches the local audio engine")
    func remoteQueueExcludesUnpreparedSongs() async throws {
        let engine = SafetyAudioEngine()
        let cachedURL = URL(fileURLWithPath: "/Cache/verified-first.mp3")
        let controller = PlaybackController(
            engine: engine,
            prepareSong: PrepareSongForPlayback(
                downloader: SafetyDownloader(url: cachedURL),
                verifier: SafetyVerifier()
            ),
            mediaLocationResolver: { song in
                .remote(
                    RemoteMedia(
                        trackID: song.libraryID,
                        contentHash: String(repeating: "c", count: 64),
                        byteCount: 1,
                        downloadURL: song.url
                    )
                )
            }
        )
        defer { controller.stopAndClear() }
        let first = remoteSong(named: "first")
        let second = remoteSong(named: "second")

        controller.play(song: first, queue: [first, second])
        for _ in 0 ..< 50 where controller.state != .playing {
            await Task.yield()
        }

        #expect(controller.state == .playing)
        #expect(engine.loadedSongs.map(\.url) == [cachedURL])
        let loadedOnlyLocalFiles = engine.loadedSongs.allSatisfy { song in
            song.url.isFileURL
        }
        #expect(loadedOnlyLocalFiles)
        #expect(engine.loadedStartingIndex == 0)
    }

    private func remoteSong(named name: String) -> Song {
        Song(
            url: URL(string: "https://mercury/v1/blobs/\(name)")!,
            title: name,
            artist: "Artist",
            duration: 180
        )
    }
}

@MainActor
private final class SafetyAudioEngine: AudioPlaybackEngine {
    var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) -> Void)?
    var levelHandler: (@MainActor @Sendable ([Double]) -> Void)?
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var outputStatus = PlaybackOutputStatus()
    var loadedSongs: [Song] = []
    var loadedStartingIndex: Int?

    func load(
        items: [PlaybackQueueItem],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval {
        let songs = items.map(\.song)
        loadedSongs = songs
        loadedStartingIndex = index
        currentTime = time
        return songs[index].duration ?? 0
    }

    func play() throws {}
    func pause() {}
    func stop() {}

    func seek(
        to time: TimeInterval,
        playbackID: UUID,
        shouldPlay: Bool
    ) throws {
        currentTime = time
    }
}

private struct SafetyDownloader: RemoteMediaDownloading {
    let url: URL

    func download(_ media: RemoteMedia) async throws -> URL {
        url
    }
}

private struct SafetyVerifier: MediaHashVerifying {
    func verify(file: URL, expectedSHA256: String) async throws {}
}
#endif
