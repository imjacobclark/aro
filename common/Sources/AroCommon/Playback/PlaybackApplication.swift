import Foundation

public struct PlaybackRoutePolicy: Sendable {
    public init() {}

    public func effectiveMode(
        preferredMode: PlaybackMode,
        device: AudioOutputDevice?
    ) -> PlaybackMode {
        device?.transport.isWireless == true ? .normalized : preferredMode
    }

    public func allowsExclusiveAccess(for device: AudioOutputDevice?) -> Bool {
        device?.transport.isWireless != true
    }

    public func warning(for device: AudioOutputDevice?) -> String? {
        guard let device, device.transport.isWireless else { return nil }
        return "Wireless output uses shared normalized playback and may introduce latency."
    }

    public func loudnessGateError(
        effectiveMode: PlaybackMode,
        leadSongLoudness: LoudnessAnalysis?
    ) -> PlaybackEngineError? {
        guard effectiveMode == .normalized, leadSongLoudness == nil else {
            return nil
        }
        return .missingLoudnessAnalysis
    }
}

public enum PlaybackEngineError: LocalizedError, Sendable, Equatable {
    case invalidAudioFile
    case missingAudioProperties
    case missingLoudnessAnalysis
    case outputDeviceMismatch(requested: String, actual: String)
    case engineFailedToStart(String)
    case progressiveStreamingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudioFile:
            return "The audio file is empty or has an unsupported format."
        case .missingAudioProperties:
            return "The song’s sample rate could not be determined."
        case .missingLoudnessAnalysis:
            return "The song must be analyzed before normalized playback can begin."
        case .outputDeviceMismatch(let requested, let actual):
            return "The selected output could not route playback to \(requested). The active output is \(actual)."
        case .engineFailedToStart(let message):
            return "The audio engine could not start: \(message)"
        case .progressiveStreamingFailed(let message):
            return "Progressive streaming could not start: \(message)"
        }
    }
}

public enum PlaybackEngineEvent: Sendable {
    case started(UUID, URL, TimeInterval)
    case finished(UUID)
    case failed(String)
    case progressiveStreamingFailed(UUID, String)
}

public struct PlaybackQueueItem: Hashable, Sendable {
    public let song: Song
    public let location: PlaybackMediaLocation

    public init(song: Song, location: PlaybackMediaLocation) {
        self.song = song
        self.location = location
    }
}

public struct PreparedPlaybackQueue: Sendable {
    public let songs: [Song]
    public let selectedIndex: Int

    public init(songs: [Song], selectedIndex: Int) {
        self.songs = songs
        self.selectedIndex = selectedIndex
    }
}

public struct ReconciledPlaybackQueue: Sendable {
    public let songs: [Song]
    public let currentSong: Song?
    public let currentIndex: Int?

    public init(songs: [Song], currentSong: Song?, currentIndex: Int?) {
        self.songs = songs
        self.currentSong = currentSong
        self.currentIndex = currentIndex
    }
}

public struct PlaybackQueuePolicy: Sendable {
    public init() {}

    public func prepare(selectedSong: Song, requestedQueue: [Song]) -> PreparedPlaybackQueue {
        var seenIDs = Set<String>()
        let songs = requestedQueue.filter { seenIDs.insert($0.id).inserted }
        guard let index = songs.firstIndex(where: { $0.id == selectedSong.id }) else {
            return PreparedPlaybackQueue(songs: [selectedSong], selectedIndex: 0)
        }
        return PreparedPlaybackQueue(songs: songs, selectedIndex: index)
    }

    public func reconcile(queue: [Song], currentSong: Song?, availableSongs: [Song]) -> ReconciledPlaybackQueue {
        let availableByID = Dictionary(uniqueKeysWithValues: availableSongs.map { ($0.id, $0) })
        let songs = queue.compactMap { availableByID[$0.id] }
        let updatedCurrent = currentSong.flatMap { availableByID[$0.id] }
        return ReconciledPlaybackQueue(
            songs: songs,
            currentSong: updatedCurrent,
            currentIndex: updatedCurrent.flatMap { current in songs.firstIndex { $0.id == current.id } }
        )
    }
}

@MainActor
public protocol AudioPlaybackEngine: AnyObject {
    var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) -> Void)? { get set }
    var levelHandler: (@MainActor @Sendable ([Double]) -> Void)? { get set }
    var currentTime: TimeInterval { get }
    var volume: Float { get set }
    var outputStatus: PlaybackOutputStatus { get }
    var bufferedFraction: Double { get }
    var isWaitingForData: Bool { get }

    func load(
        items: [PlaybackQueueItem],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval
    func play() throws
    func pause()
    func seek(to time: TimeInterval, playbackID: UUID, shouldPlay: Bool) throws
    func stop()
}

public extension AudioPlaybackEngine {
    var bufferedFraction: Double { 1 }
    var isWaitingForData: Bool { false }
}

public protocol ListeningHistoryRecording: Sendable {
    func beginSession(trackID: UUID) -> UUID
    func heartbeat(sessionID: UUID)
    func endSession(sessionID: UUID, completed: Bool)
}

public struct NoOpListeningHistoryRecorder: ListeningHistoryRecording, Sendable {
    public init() {}

    public func beginSession(trackID: UUID) -> UUID { UUID() }
    public func heartbeat(sessionID: UUID) {}
    public func endSession(sessionID: UUID, completed: Bool) {}
}

public protocol PlaybackActivityReporting: Sendable {
    func report(_ snapshot: PlaybackActivitySnapshot)
}

public struct NoOpPlaybackActivityReporter: PlaybackActivityReporting, Sendable {
    public init() {}
    public func report(_ snapshot: PlaybackActivitySnapshot) {}
}

public protocol NowPlayingPublishing: Sendable {
    func publish(
        song: Song?,
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    )
}

public struct NoOpNowPlayingPublisher: NowPlayingPublishing, Sendable {
    public init() {}

    public func publish(
        song: Song?,
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {}
}

public struct PlaybackPreferenceValues: Sendable {
    public var mode: PlaybackMode = .bitPerfect
    public var outputDeviceUID: String?
    public var hogModeEnabled = false
    public var targetLUFS = -14.0
    public var shuffleEnabled = false
    public var repeatMode: PlaybackRepeatMode = .off

    public init(
        mode: PlaybackMode = .bitPerfect,
        outputDeviceUID: String? = nil,
        hogModeEnabled: Bool = false,
        targetLUFS: Double = -14.0,
        shuffleEnabled: Bool = false,
        repeatMode: PlaybackRepeatMode = .off
    ) {
        self.mode = mode
        self.outputDeviceUID = outputDeviceUID
        self.hogModeEnabled = hogModeEnabled
        self.targetLUFS = targetLUFS
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
    }
}

public extension PlaybackOutputStatus {
    var fidelityLabel: String {
        if transport.isWireless { return "Shared Normalized" }
        if mode == .normalized { return "Normalized" }
        return isExclusive ? "Exclusive Bit-Perfect" : "Native / Shared"
    }

    var formatLabel: String {
        var parts: [String] = []
        if let sampleRate {
            let rate = (sampleRate / 1_000).formatted(
                .number.precision(.fractionLength(0...1))
            )
            parts.append("\(rate) kHz")
        }
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        return parts.joined(separator: " · ")
    }
}

public protocol PlaybackPreferenceStoring: Sendable {
    func load() -> PlaybackPreferenceValues
    func save(_ values: PlaybackPreferenceValues)
}

@MainActor
public final class ListeningSessionTracker {
    private let history: any ListeningHistoryRecording
    private let activity: any PlaybackActivityReporting
    private var sessionID: UUID?
    private var lastHeartbeat = Date.distantPast
    private var startedAt = Date.distantPast
    private var contentHash: String?
    private var revision: UInt64 = 0
    private var position: TimeInterval = 0
    private var duration: TimeInterval?
    private var bufferedFraction: Double?
    private var output: PlaybackOutputSnapshot?

    public init(
        history: any ListeningHistoryRecording,
        activity: any PlaybackActivityReporting =
            NoOpPlaybackActivityReporter()
    ) {
        self.history = history
        self.activity = activity
    }

    public func begin(
        trackID: UUID,
        contentHash: String?,
        outputStatus: PlaybackOutputStatus,
        now: Date = Date()
    ) {
        guard sessionID == nil else { return }
        sessionID = history.beginSession(trackID: trackID)
        self.contentHash = contentHash
        startedAt = now
        lastHeartbeat = now
        revision = 0
        position = 0
        output = PlaybackOutputSnapshot(status: outputStatus)
        emit(state: .playing, completed: false, now: now)
    }

    public func begin(trackID: UUID, now: Date = Date()) {
        begin(
            trackID: trackID,
            contentHash: nil,
            outputStatus: PlaybackOutputStatus(),
            now: now
        )
    }

    public func heartbeatIfNeeded(
        position: TimeInterval,
        duration: TimeInterval,
        bufferedFraction: Double,
        buffering: Bool,
        outputStatus: PlaybackOutputStatus,
        at now: Date = Date()
    ) {
        guard now.timeIntervalSince(lastHeartbeat) >= 5, let sessionID else { return }
        history.heartbeat(sessionID: sessionID)
        self.position = position
        self.duration = duration
        self.bufferedFraction = bufferedFraction
        output = PlaybackOutputSnapshot(status: outputStatus)
        emit(state: buffering ? .buffering : .playing, completed: false, now: now)
        lastHeartbeat = now
    }

    public func heartbeatIfNeeded(at now: Date = Date()) {
        heartbeatIfNeeded(
            position: position,
            duration: duration ?? 0,
            bufferedFraction: bufferedFraction ?? 1,
            buffering: false,
            outputStatus: PlaybackOutputStatus(),
            at: now
        )
    }

    public func end(completed: Bool = false) {
        guard let sessionID else { return }
        history.endSession(sessionID: sessionID, completed: completed)
        emit(state: .stopped, completed: completed, now: Date())
        self.sessionID = nil
        lastHeartbeat = .distantPast
        contentHash = nil
        revision = 0
    }

    private func emit(
        state: PlaybackActivityState,
        completed: Bool,
        now: Date
    ) {
        guard let sessionID, let contentHash else { return }
        revision += 1
        activity.report(
            PlaybackActivitySnapshot(
                sessionID: sessionID,
                revision: revision,
                contentHash: contentHash,
                state: state,
                positionSeconds: position,
                durationSeconds: duration,
                bufferedFraction: bufferedFraction,
                observedAt: now,
                startedAt: startedAt,
                completed: completed,
                output: output
            )
        )
    }
}
