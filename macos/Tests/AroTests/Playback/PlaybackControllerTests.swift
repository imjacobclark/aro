#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testBuildsQueueAndAutomaticallyAdvances() throws {
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(engine: engine)
        let songs = makeSongs(["Alpha", "Beta", "Gamma"])
        defer { controller.stopAndClear() }

        controller.play(song: songs[1], queue: songs)

        XCTAssertEqual(controller.currentSong, songs[1])
        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertEqual(controller.state, .playing)

        let betaPlaybackID = try XCTUnwrap(engine.playbackID)
        engine.finish(playbackID: betaPlaybackID)

        XCTAssertEqual(controller.currentSong, songs[2])
        XCTAssertEqual(controller.currentIndex, 2)

        let gammaPlaybackID = try XCTUnwrap(engine.playbackID)
        engine.currentTime = engine.loadedDuration
        engine.finish(playbackID: gammaPlaybackID)

        XCTAssertEqual(controller.currentSong, songs[2])
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.elapsedTime, controller.duration)
    }

    func testPreviousRestartsAfterThreeSecondsOtherwiseMovesBack() {
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(engine: engine)
        let songs = makeSongs(["Alpha", "Beta"])
        defer { controller.stopAndClear() }

        controller.play(song: songs[1], queue: songs)
        controller.seek(to: 4)
        controller.previous()

        XCTAssertEqual(controller.currentSong, songs[1])
        XCTAssertEqual(controller.elapsedTime, 0)

        controller.seek(to: 2)
        controller.previous()

        XCTAssertEqual(controller.currentSong, songs[0])
        XCTAssertEqual(controller.elapsedTime, 0)
    }

    func testClampsSeekAndVolume() {
        let seekEngine = FakeAudioPlaybackEngine()
        let seekController = PlaybackController(engine: seekEngine)
        let song = makeSongs(["Alpha"])[0]

        seekController.play(song: song, queue: [song])
        seekController.seek(to: 10_000)
        XCTAssertEqual(seekController.elapsedTime, seekEngine.loadedDuration)
        seekController.stopAndClear()

        let preferences = PlaybackPreferences(
            store: InMemoryPlaybackPreferenceStore()
        )
        preferences.mode = .normalized
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences
        )

        controller.setVolume(-2)
        XCTAssertEqual(controller.volume, 0)
        XCTAssertEqual(engine.volume, 0)

        controller.setVolume(4)
        XCTAssertEqual(controller.volume, 1)
        XCTAssertEqual(engine.volume, 1)
    }

    func testIgnoresStaleCompletionEvents() throws {
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(engine: engine)
        let songs = makeSongs(["Alpha", "Beta"])
        defer { controller.stopAndClear() }

        controller.play(song: songs[0], queue: songs)
        let stalePlaybackID = try XCTUnwrap(engine.playbackID)
        controller.play(song: songs[1], queue: songs)

        engine.finish(playbackID: stalePlaybackID)

        XCTAssertEqual(controller.currentSong, songs[1])
        XCTAssertEqual(controller.state, .playing)
    }

    func testReconcilesRemovedAndOverlappingSongs() {
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(engine: engine)
        let songs = makeSongs(["Alpha", "Beta"])

        controller.play(song: songs[0], queue: songs)
        controller.reconcileAvailableSongs([songs[0]])

        XCTAssertEqual(controller.currentSong, songs[0])
        XCTAssertEqual(controller.queue, [songs[0]])

        controller.reconcileAvailableSongs([])

        XCTAssertNil(controller.currentSong)
        XCTAssertTrue(controller.queue.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testSettingsRestartPreservesPositionAndPauseState() {
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(engine: engine)
        let song = makeSongs(["Alpha"])[0]
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        controller.seek(to: 42)
        controller.togglePlayPause()

        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(engine.playCount, 1)

        controller.restartForPlaybackSettingsChange()

        XCTAssertEqual(engine.loadedFrom, 42)
        XCTAssertEqual(controller.elapsedTime, 42)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(engine.playCount, 1)

        controller.togglePlayPause()
        controller.restartForPlaybackSettingsChange()

        XCTAssertEqual(engine.loadedFrom, 42)
        XCTAssertEqual(controller.elapsedTime, 42)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.playCount, 3)
    }

    func testRemoteTrackIsPreparedBeforeEngineLoad() async throws {
        let engine = FakeAudioPlaybackEngine()
        let cachedURL = URL(fileURLWithPath: "/Cache/verified.flac")
        let prepare = PrepareSongForPlayback(
            downloader: FakeRemoteDownloader(url: cachedURL),
            verifier: FakeMediaVerifier()
        )
        let controller = PlaybackController(
            engine: engine,
            prepareSong: prepare,
            mediaLocationResolver: { song in
                .remote(
                    RemoteMedia(
                        trackID: song.libraryID,
                        contentHash: String(repeating: "a", count: 64),
                        byteCount: 1,
                        downloadURL: song.url
                    )
                )
            }
        )
        let song = Song(
            url: URL(string: "https://hub/v1/blobs/hash")!,
            title: "Remote",
            artist: "Artist",
            duration: 180
        )
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        for _ in 0 ..< 20 where controller.state != .playing {
            await Task.yield()
        }

        XCTAssertEqual(engine.loadedURL, cachedURL)
        XCTAssertEqual(controller.currentSong?.url, cachedURL)
        XCTAssertEqual(controller.state, .playing)
    }

    func testRemoteQueueNeverPassesUnpreparedURLToAudioEngine() async throws {
        let engine = FakeAudioPlaybackEngine()
        let cachedURL = URL(fileURLWithPath: "/Cache/verified-first.mp3")
        let prepare = PrepareSongForPlayback(
            downloader: FakeRemoteDownloader(url: cachedURL),
            verifier: FakeMediaVerifier()
        )
        let controller = PlaybackController(
            engine: engine,
            prepareSong: prepare,
            mediaLocationResolver: { song in
                .remote(
                    RemoteMedia(
                        trackID: song.libraryID,
                        contentHash: String(repeating: "b", count: 64),
                        byteCount: 1,
                        downloadURL: song.url
                    )
                )
            }
        )
        let first = Song(
            url: URL(string: "https://mercury/v1/blobs/first")!,
            title: "First",
            artist: "Artist",
            duration: 180
        )
        let second = Song(
            url: URL(string: "https://mercury/v1/blobs/second")!,
            title: "Second",
            artist: "Artist",
            duration: 180
        )
        defer { controller.stopAndClear() }

        controller.play(song: first, queue: [first, second])
        for _ in 0 ..< 20 where controller.state != .playing {
            await Task.yield()
        }

        XCTAssertEqual(engine.loadedSongs.map(\.url), [cachedURL])
        XCTAssertTrue(engine.loadedSongs.allSatisfy(\.url.isFileURL))
        XCTAssertEqual(engine.loadedStartingIndex, 0)
    }

    private func makeSongs(_ titles: [String]) -> [Song] {
        titles.map {
            Song(
                url: URL(fileURLWithPath: "/Music/\($0).wav"),
                title: $0,
                artist: "Artist",
                duration: 180,
                audioProperties: AudioFileProperties(
                    codec: "WAVE",
                    sampleRate: 96_000,
                    bitDepth: 24,
                    channelCount: 2,
                    bitrate: nil
                )
            )
        }
    }
}

@MainActor
private final class FakeAudioPlaybackEngine: AudioPlaybackEngine {
    var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) -> Void)?
    var levelHandler: (@MainActor @Sendable ([Double]) -> Void)?
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var outputStatus = PlaybackOutputStatus()

    var playbackID: UUID?
    var loadedDuration: TimeInterval = 180
    var loadedFrom: TimeInterval = 0
    var playCount = 0
    var stopCount = 0
    var loadedURL: URL?
    var loadedSongs: [Song] = []
    var loadedStartingIndex: Int?

    func load(
        songs: [Song],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval {
        self.playbackID = playbackID
        loadedSongs = songs
        loadedStartingIndex = index
        loadedURL = songs[index].url
        currentTime = time
        loadedFrom = time
        return loadedDuration
    }

    func play() throws {
        playCount += 1
    }

    func pause() {}

    func seek(
        to time: TimeInterval,
        playbackID: UUID,
        shouldPlay: Bool
    ) throws {
        self.playbackID = playbackID
        currentTime = time
    }

    func stop() {
        stopCount += 1
        playbackID = nil
        currentTime = 0
    }

    func finish(playbackID: UUID) {
        eventHandler?(.finished(playbackID))
    }
}

private struct FakeRemoteDownloader: RemoteMediaDownloading {
    let url: URL

    func download(_ media: RemoteMedia) async throws -> URL {
        url
    }
}

private struct FakeMediaVerifier: MediaHashVerifying {
    func verify(file: URL, expectedSHA256: String) async throws {}
}
#endif
