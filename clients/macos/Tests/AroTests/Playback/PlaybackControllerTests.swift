#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testLocalServerOutageBlocksOriginalAndCachedPlayback() {
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(engine: engine)
        let song = makeSongs(["Local file"])[0]

        controller.setServerUnavailable("The local library server is unavailable.")
        controller.play(song: song, queue: [song])

        XCTAssertFalse(controller.canTogglePlayback)
        XCTAssertNil(engine.loadedURL)
        XCTAssertEqual(
            controller.errorMessage,
            "The local library server is unavailable."
        )
    }

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

    func testRestartRoundTripKeepsEngineVolumeInSyncWithControllerVolume() {
        let preferences = PlaybackPreferences(
            store: InMemoryPlaybackPreferenceStore()
        )
        preferences.mode = .normalized
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences
        )
        let song = makeSongs(["Alpha"])[0]
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        controller.setVolume(0.3)
        XCTAssertEqual(controller.volume, 0.3, accuracy: 0.0001)
        XCTAssertEqual(engine.volume, 0.3, accuracy: 0.0001)

        // Bit-perfect cannot apply software gain, so the graph goes to unity — but the
        // listener's choice is remembered rather than overwritten. It used to be
        // destroyed here, so a round trip through bit-perfect silently returned to full
        // scale, which on a hi-fi is a good deal worse than a cosmetic bug.
        preferences.mode = .bitPerfect
        controller.restartForPlaybackSettingsChange()
        XCTAssertEqual(engine.volume, 1, "bit-perfect must reach the graph at unity")
        XCTAssertEqual(
            controller.volume,
            0.3,
            accuracy: 0.0001,
            "the requested volume must survive a mode that cannot apply it"
        )

        preferences.mode = .normalized
        controller.restartForPlaybackSettingsChange()
        XCTAssertEqual(
            controller.volume,
            0.3,
            accuracy: 0.0001,
            "returning to normalized must restore the volume the listener chose"
        )
        XCTAssertEqual(
            controller.volume,
            Double(engine.volume),
            accuracy: 0.0001,
            "controller.volume must stay in sync with engine.volume after a restart"
        )
    }

    /// Volume used to be forgotten on every launch, so an amplifier left turned up met
    /// full-scale output the next time Aro opened.
    func testVolumeIsRestoredFromPreferencesOnLaunch() {
        let store = InMemoryPlaybackPreferenceStore()
        let first = PlaybackPreferences(store: store)
        first.mode = .normalized
        let controller = PlaybackController(
            engine: FakeAudioPlaybackEngine(),
            preferences: first
        )
        controller.setVolume(0.25)

        let relaunched = PlaybackPreferences(store: store)
        let restored = PlaybackController(
            engine: FakeAudioPlaybackEngine(),
            preferences: relaunched
        )
        XCTAssertEqual(restored.volume, 0.25, accuracy: 0.0001)
    }

    func testWirelessAwareResolverAvoidsForcingBitPerfectVolumeBehavior() {
        let preferences = PlaybackPreferences(
            store: InMemoryPlaybackPreferenceStore()
        )
        preferences.mode = .bitPerfect
        let deviceManager = FakeWirelessAudioDeviceManager()
        let engine = FakeAudioPlaybackEngine()

        // Mirrors how LibraryRuntime wires PlaybackController in production:
        // the resolver must account for the wireless device forcing
        // normalized mode, not just echo `preferences.mode` like the
        // controller's own default resolver does.
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences,
            effectiveModeResolver: {
                PlaybackRoutePolicy().effectiveMode(
                    preferredMode: preferences.mode,
                    device: deviceManager.selectedDevice(
                        for: preferences.outputDeviceUID
                    )
                )
            }
        )
        let song = makeSongs(["Alpha"])[0]
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        controller.setVolume(0.5)

        XCTAssertEqual(
            controller.volume,
            0.5,
            "a wireless device forces normalized mode, so volume should " +
                "follow the requested value rather than being clamped to " +
                "1 as it would under bit-perfect"
        )
        XCTAssertEqual(Double(engine.volume), 0.5, accuracy: 0.0001)
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

    func testEligibleRemoteTrackStartsWithProgressiveLocation() {
        let engine = FakeAudioPlaybackEngine()
        let hash = String(repeating: "c", count: 64)
        let song = Song(
            url: URL(string: "https://hub/v1/blobs/\(hash)")!,
            title: "Progressive",
            artist: "Artist",
            duration: 180,
            fileSizeBytes: 12_000_000,
            audioProperties: AudioFileProperties(
                codec: "flac",
                sampleRate: 96_000,
                bitDepth: 24,
                channelCount: 2,
                bitrate: 800_000
            ),
            contentHash: hash
        )
        let controller = PlaybackController(
            engine: engine,
            mediaLocationResolver: { song in
                .remote(
                    RemoteMedia(
                        trackID: song.libraryID,
                        contentHash: hash,
                        byteCount: 12_000_000,
                        downloadURL: song.url
                    )
                )
            },
            progressivePlaybackEligibility: { _ in true }
        )
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])

        guard case .remote(let media) = engine.loadedItems.first?.location else {
            return XCTFail("Expected a progressive remote playback item")
        }
        XCTAssertEqual(media.contentHash, hash)
        XCTAssertEqual(controller.currentSong?.url, song.url)
        XCTAssertEqual(controller.state, .playing)
    }

    func testNormalizedRemoteTrackNeverDownloadsBeforeStreaming() {
        let engine = FakeAudioPlaybackEngine()
        let preferences = PlaybackPreferences(
            store: InMemoryPlaybackPreferenceStore()
        )
        preferences.mode = .normalized
        let hash = String(repeating: "9", count: 64)
        let song = Song(
            url: URL(string: "https://hub/v1/blobs/\(hash)")!,
            title: "Server Analyzed",
            artist: "Artist",
            duration: 180,
            fileSizeBytes: 12_000_000,
            audioProperties: AudioFileProperties(
                codec: "m4a",
                sampleRate: 44_100,
                bitDepth: 16,
                channelCount: 2,
                bitrate: 900_000
            ),
            contentHash: hash
        )
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences,
            effectiveModeResolver: { .normalized },
            prepareSong: PrepareSongForPlayback(
                downloader: FailingRemoteDownloader(),
                verifier: FakeMediaVerifier()
            ),
            mediaLocationResolver: { candidate in
                .remote(
                    RemoteMedia(
                        trackID: candidate.libraryID,
                        contentHash: hash,
                        byteCount: 12_000_000,
                        downloadURL: candidate.url
                    )
                )
            },
            progressivePlaybackEligibility: { _ in true }
        )
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])

        guard case .remote = engine.loadedItems.first?.location else {
            return XCTFail("Normalized playback must enter streaming directly")
        }
        XCTAssertEqual(controller.state, .playing)
        XCTAssertNil(controller.errorMessage)
    }

    func testProgressiveFailureDownloadsAndResumesVerifiedSong() async throws {
        let engine = FakeAudioPlaybackEngine()
        let cachedURL = URL(fileURLWithPath: "/Cache/fallback.flac")
        let prepare = PrepareSongForPlayback(
            downloader: FakeRemoteDownloader(url: cachedURL),
            verifier: FakeMediaVerifier()
        )
        let hash = String(repeating: "d", count: 64)
        let song = Song(
            url: URL(string: "https://hub/v1/blobs/\(hash)")!,
            title: "Fallback",
            artist: "Artist",
            duration: 180,
            fileSizeBytes: 12_000_000,
            audioProperties: AudioFileProperties(
                codec: "flac",
                sampleRate: 44_100,
                bitDepth: 16,
                channelCount: 2,
                bitrate: 900_000
            ),
            contentHash: hash
        )
        let controller = PlaybackController(
            engine: engine,
            prepareSong: prepare,
            mediaLocationResolver: { candidate in
                if candidate.url.isFileURL {
                    return .local(candidate.url)
                }
                return .remote(
                    RemoteMedia(
                        trackID: candidate.libraryID,
                        contentHash: hash,
                        byteCount: 12_000_000,
                        downloadURL: candidate.url
                    )
                )
            },
            progressivePlaybackEligibility: { _ in true }
        )
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        let playbackID = try XCTUnwrap(engine.playbackID)
        engine.currentTime = 42
        engine.failProgressive(
            playbackID: playbackID,
            message: "range connection lost"
        )
        for _ in 0..<100 where engine.loadedURL != cachedURL {
            await Task.yield()
        }

        XCTAssertEqual(engine.loadedURL, cachedURL)
        XCTAssertEqual(engine.loadedFrom, 42)
        XCTAssertEqual(controller.currentSong?.url, cachedURL)
        XCTAssertEqual(controller.state, .playing)
    }

    func testDuplicateProgressiveFailureDoesNotCancelActiveFallback()
        async throws {
        let engine = FakeAudioPlaybackEngine()
        let cachedURL = URL(fileURLWithPath: "/Cache/fallback.mp3")
        let prepare = PrepareSongForPlayback(
            downloader: FakeRemoteDownloader(url: cachedURL),
            verifier: FakeMediaVerifier()
        )
        let hash = String(repeating: "e", count: 64)
        let song = Song(
            url: URL(string: "https://hub/v1/blobs/\(hash)")!,
            title: "Fallback",
            artist: "Artist",
            duration: 180,
            fileSizeBytes: 8_000_000,
            audioProperties: AudioFileProperties(
                codec: "mp3",
                sampleRate: 44_100,
                bitDepth: 16,
                channelCount: 2,
                bitrate: 320_000
            ),
            contentHash: hash
        )
        let controller = PlaybackController(
            engine: engine,
            prepareSong: prepare,
            mediaLocationResolver: { candidate in
                candidate.url.isFileURL
                    ? .local(candidate.url)
                    : .remote(
                        RemoteMedia(
                            trackID: candidate.libraryID,
                            contentHash: hash,
                            byteCount: 8_000_000,
                            downloadURL: candidate.url
                        )
                    )
            },
            progressivePlaybackEligibility: { _ in true }
        )
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        let playbackID = try XCTUnwrap(engine.playbackID)
        engine.failProgressive(
            playbackID: playbackID,
            message: "first failure"
        )
        engine.failProgressive(
            playbackID: playbackID,
            message: "duplicate failure"
        )
        for _ in 0..<100 where engine.loadedURL != cachedURL {
            await Task.yield()
        }

        XCTAssertEqual(engine.loadedURL, cachedURL)
        XCTAssertEqual(controller.state, .playing)
    }

    func testFailedDownloadFallbackReportsBothCauses() async throws {
        let engine = FakeAudioPlaybackEngine()
        let prepare = PrepareSongForPlayback(
            downloader: FailingRemoteDownloader(),
            verifier: FakeMediaVerifier()
        )
        let hash = String(repeating: "f", count: 64)
        let song = Song(
            url: URL(string: "https://hub/v1/blobs/\(hash)")!,
            title: "Unavailable",
            artist: "Artist",
            duration: 180,
            fileSizeBytes: 4_000_000,
            audioProperties: AudioFileProperties(
                codec: "m4a",
                sampleRate: 44_100,
                bitDepth: 16,
                channelCount: 2,
                bitrate: 256_000
            ),
            contentHash: hash
        )
        let controller = PlaybackController(
            engine: engine,
            prepareSong: prepare,
            mediaLocationResolver: { candidate in
                .remote(
                    RemoteMedia(
                        trackID: candidate.libraryID,
                        contentHash: hash,
                        byteCount: 4_000_000,
                        downloadURL: candidate.url
                    )
                )
            },
            progressivePlaybackEligibility: { _ in true }
        )
        defer { controller.stopAndClear() }

        controller.play(song: song, queue: [song])
        let playbackID = try XCTUnwrap(engine.playbackID)
        engine.failProgressive(
            playbackID: playbackID,
            message: "decoder stopped"
        )
        for _ in 0..<100 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertEqual(controller.state, .failed(
            "Streaming failed: decoder stopped Download fallback failed: download unavailable"
        ))
    }

    func testShuffleKeepsRequestedSongFirstAndPersistsPreference() {
        let preferencesStore = InMemoryPlaybackPreferenceStore(
            values: PlaybackPreferenceValues(shuffleEnabled: true)
        )
        let preferences = PlaybackPreferences(store: preferencesStore)
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences
        )
        let songs = makeSongs(["Alpha", "Beta", "Gamma", "Delta"])
        defer { controller.stopAndClear() }

        controller.play(song: songs[1], queue: songs)

        XCTAssertEqual(controller.currentSong, songs[1])
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(Set(controller.queue), Set(songs))
        XCTAssertTrue(controller.isShuffleEnabled)

        controller.toggleShuffle()
        XCTAssertFalse(controller.isShuffleEnabled)
        XCTAssertFalse(preferencesStore.load().shuffleEnabled)
    }

    func testRepeatOneReloadsOnlyCurrentSongAndManualNextAdvances() throws {
        let preferences = PlaybackPreferences(
            store: InMemoryPlaybackPreferenceStore(
                values: PlaybackPreferenceValues(repeatMode: .one)
            )
        )
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences
        )
        let songs = makeSongs(["Alpha", "Beta"])
        defer { controller.stopAndClear() }

        controller.play(song: songs[0], queue: songs)
        XCTAssertEqual(engine.loadedItems.map(\.song), [songs[0]])

        let firstPlaybackID = try XCTUnwrap(engine.playbackID)
        engine.finish(playbackID: firstPlaybackID)
        XCTAssertEqual(controller.currentSong, songs[0])
        XCTAssertEqual(controller.state, .playing)

        controller.next()
        XCTAssertEqual(controller.currentSong, songs[1])
    }

    func testRepeatAllWrapsAtEndOfQueue() throws {
        let preferences = PlaybackPreferences(
            store: InMemoryPlaybackPreferenceStore(
                values: PlaybackPreferenceValues(repeatMode: .all)
            )
        )
        let engine = FakeAudioPlaybackEngine()
        let controller = PlaybackController(
            engine: engine,
            preferences: preferences
        )
        let songs = makeSongs(["Alpha", "Beta"])
        defer { controller.stopAndClear() }

        controller.play(song: songs[1], queue: songs)
        let playbackID = try XCTUnwrap(engine.playbackID)
        engine.finish(playbackID: playbackID)

        XCTAssertEqual(controller.currentSong, songs[0])
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.state, .playing)
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
    var loadedItems: [PlaybackQueueItem] = []
    var loadedStartingIndex: Int?

    func load(
        items: [PlaybackQueueItem],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval {
        let songs = items.map(\.song)
        loadedItems = items
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

    func failProgressive(playbackID: UUID, message: String) {
        eventHandler?(
            .progressiveStreamingFailed(playbackID, message)
        )
    }
}

@MainActor
private final class FakeWirelessAudioDeviceManager: AudioDeviceManaging {
    let wirelessDevice = AudioOutputDevice(
        id: 99,
        uid: "wireless",
        name: "Wireless Speaker",
        sampleRateRanges: [],
        transport: .bluetooth
    )
    var devices: [AudioOutputDevice] { [wirelessDevice] }
    var lastWarning: String?
    var defaultDevice: AudioOutputDevice? { wirelessDevice }
    var defaultDeviceDidChange: ((AudioOutputDevice?) -> Void)?

    func refresh() {}
    func setSystemDefaultOutputDevice(_ device: AudioOutputDevice) -> Bool { true }
    func selectedDevice(for uid: String?) -> AudioOutputDevice? { wirelessDevice }
    func device(withID id: UInt32) -> AudioOutputDevice? { wirelessDevice }
    func nominalSampleRate(for device: AudioOutputDevice) -> Double? { nil }
    func configure(
        device: AudioOutputDevice,
        sampleRate: Double,
        acquireHogMode: Bool
    ) throws -> Bool { false }
    func releaseHogMode(for device: AudioOutputDevice?) {}
}

private struct FakeRemoteDownloader: RemoteMediaDownloading {
    let url: URL

    func download(_ media: RemoteMedia) async throws -> URL {
        url
    }
}

private struct FailingRemoteDownloader: RemoteMediaDownloading {
    func download(_ media: RemoteMedia) async throws -> URL {
        throw FailingDownloadError()
    }
}

private struct FailingDownloadError: LocalizedError {
    var errorDescription: String? { "download unavailable" }
}

private struct FakeMediaVerifier: MediaHashVerifying {
    func verify(file: URL, expectedSHA256: String) async throws {}
}
#endif
