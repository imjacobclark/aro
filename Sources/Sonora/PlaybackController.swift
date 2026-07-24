import Foundation
import Observation

enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed(String)
}

@MainActor
@Observable
final class PlaybackController {
    private(set) var state: PlaybackState = .idle
    private(set) var currentSong: Song?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    private(set) var volume: Double = 1
    private(set) var outputStatus = PlaybackOutputStatus()
    private(set) var visualizerLevels = Array(repeating: 0.0, count: 9)

    @ObservationIgnored private var engine: (any AudioPlaybackEngine)?
    @ObservationIgnored private let engineFactory: @MainActor () -> any AudioPlaybackEngine
    @ObservationIgnored private let preferences: PlaybackPreferences
    @ObservationIgnored private let loudnessService: LoudnessAnalysisService
    @ObservationIgnored private let database: LibraryDatabase
    @ObservationIgnored private var playbackID = UUID()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var listeningSessionID: UUID?
    @ObservationIgnored private var lastListeningHeartbeat = Date.distantPast

    init(
        engine: (any AudioPlaybackEngine)? = nil,
        preferences: PlaybackPreferences = PlaybackPreferences(),
        deviceManager: AudioDeviceManager = AudioDeviceManager(),
        loudnessService: LoudnessAnalysisService = LoudnessAnalysisService(),
        database: LibraryDatabase = .shared,
        engineFactory: (@MainActor () -> any AudioPlaybackEngine)? = nil
    ) {
        self.engine = engine
        self.preferences = preferences
        self.loudnessService = loudnessService
        self.database = database
        self.engineFactory = engineFactory ?? {
            HighResolutionPlaybackEngine(
                preferences: preferences,
                deviceManager: deviceManager
            )
        }

        if let engine {
            configure(engine)
        }
    }

    var isPlaying: Bool {
        state == .playing
    }

    var canTogglePlayback: Bool {
        currentSong != nil
    }

    var canGoPrevious: Bool {
        guard currentSong != nil else {
            return false
        }
        return elapsedTime > 0 || (currentIndex ?? 0) > 0
    }

    var canGoNext: Bool {
        guard let currentIndex else {
            return false
        }
        return currentIndex + 1 < queue.count
    }

    var errorMessage: String? {
        guard case .failed(let message) = state else {
            return nil
        }
        return message
    }

    func play(song: Song, queue requestedQueue: [Song]) {
        var seenIDs = Set<String>()
        queue = requestedQueue.filter { seenIDs.insert($0.id).inserted }

        guard let index = queue.firstIndex(where: { $0.id == song.id }) else {
            queue = [song]
            startSong(at: 0, skippingFailures: false)
            return
        }

        startSong(at: index, skippingFailures: false)
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            guard let engine else {
                return
            }
            endListeningSession()
            engine.pause()
            elapsedTime = engine.currentTime
            state = .paused
            stopProgressUpdates()
        case .paused:
            if duration > 0, elapsedTime >= duration {
                seek(to: 0)
            }
            resume()
        case .failed:
            if let currentIndex {
                startSong(at: currentIndex, skippingFailures: false)
            }
        case .idle, .loading:
            break
        }
    }

    func previous() {
        guard currentSong != nil else {
            return
        }

        if elapsedTime > 3 || (currentIndex ?? 0) == 0 {
            seek(to: 0)
            return
        }

        guard let currentIndex, currentIndex > 0 else {
            return
        }
        startSong(at: currentIndex - 1, skippingFailures: true)
    }

    func next() {
        guard let currentIndex, currentIndex + 1 < queue.count else {
            finishQueue()
            return
        }
        startSong(at: currentIndex + 1, skippingFailures: true)
    }

    func seek(to requestedTime: TimeInterval) {
        guard currentSong != nil, duration > 0 else {
            return
        }

        let clampedTime = min(max(requestedTime, 0), duration)
        let shouldPlay = state == .playing
        playbackID = UUID()

        do {
            guard let engine else {
                return
            }
            try engine.seek(
                to: clampedTime,
                playbackID: playbackID,
                shouldPlay: shouldPlay
            )
            elapsedTime = clampedTime
            state = shouldPlay ? .playing : .paused
            if shouldPlay {
                startProgressUpdates()
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func setVolume(_ requestedVolume: Double) {
        volume = preferences.mode == .bitPerfect
            ? 1
            : min(max(requestedVolume, 0), 1)
        engine?.volume = Float(volume)
    }

    func refreshNormalizedGain() {
        guard preferences.mode == .normalized, let engine else {
            return
        }
        engine.volume = Float(volume)
        outputStatus = engine.outputStatus
    }

    func restartForPlaybackSettingsChange() {
        if preferences.mode == .bitPerfect {
            volume = 1
        }
        guard currentSong != nil, let currentIndex else {
            return
        }
        let restartTime = elapsedTime
        let shouldResume = state == .playing || state == .loading
        startSong(
            at: currentIndex,
            skippingFailures: false,
            from: restartTime,
            shouldPlay: shouldResume
        )
    }

    func reconcileAvailableSongs(_ availableSongs: [Song]) {
        let availableByID = Dictionary(
            uniqueKeysWithValues: availableSongs.map { ($0.id, $0) }
        )
        queue = queue.compactMap { availableByID[$0.id] }

        guard let currentSong else {
            return
        }

        guard let updatedSong = availableByID[currentSong.id] else {
            stopAndClear()
            return
        }

        self.currentSong = updatedSong
        currentIndex = queue.firstIndex(where: { $0.id == updatedSong.id })
    }

    func stopAndClear() {
        endListeningSession()
        engine?.stop()
        stopProgressUpdates()
        preparationTask?.cancel()
        preparationTask = nil
        playbackID = UUID()
        state = .idle
        currentSong = nil
        elapsedTime = 0
        duration = 0
        queue = []
        currentIndex = nil
        visualizerLevels = Array(repeating: 0, count: 9)
    }

    private func startSong(
        at index: Int,
        skippingFailures: Bool,
        from requestedTime: TimeInterval = 0,
        shouldPlay: Bool = true
    ) {
        guard queue.indices.contains(index) else {
            finishQueue()
            return
        }

        endListeningSession()
        stopProgressUpdates()
        preparationTask?.cancel()
        preparationTask = nil
        state = .loading
        currentIndex = index
        currentSong = queue[index]
        duration = queue[index].duration ?? 0
        let startTime = min(max(requestedTime, 0), duration)
        elapsedTime = startTime
        playbackID = UUID()
        let requestedPlaybackID = playbackID

        if preferences.mode == .normalized {
            preparationTask = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.prepareLoudnessRun(
                    startingAt: index,
                    playbackID: requestedPlaybackID
                )
                guard !Task.isCancelled,
                      requestedPlaybackID == self.playbackID else {
                    return
                }
                self.startPreparedSong(
                    at: index,
                    playbackID: requestedPlaybackID,
                    skippingFailures: skippingFailures,
                    from: startTime,
                    shouldPlay: shouldPlay
                )
                self.preparationTask = nil
            }
        } else {
            startPreparedSong(
                at: index,
                playbackID: requestedPlaybackID,
                skippingFailures: skippingFailures,
                from: startTime,
                shouldPlay: shouldPlay
            )
        }
    }

    private func prepareLoudnessRun(
        startingAt index: Int,
        playbackID requestedPlaybackID: UUID
    ) async {
        guard queue.indices.contains(index) else {
            return
        }

        let sampleRate = queue[index].audioProperties?.sampleRate
        let channelCount = queue[index].audioProperties?.channelCount
        var candidateIndex = index

        while queue.indices.contains(candidateIndex),
              queue[candidateIndex].audioProperties?.sampleRate == sampleRate,
              queue[candidateIndex].audioProperties?.channelCount == channelCount,
              requestedPlaybackID == playbackID,
              !Task.isCancelled {
            let candidate = queue[candidateIndex]
            if candidate.loudness == nil {
                let analysis = await loudnessService.analysis(for: candidate)
                guard !Task.isCancelled,
                      requestedPlaybackID == playbackID,
                      queue.indices.contains(candidateIndex),
                      queue[candidateIndex].id == candidate.id else {
                    return
                }
                queue[candidateIndex].loudness = analysis
            }
            candidateIndex += 1
        }
    }

    private func startPreparedSong(
        at index: Int,
        playbackID requestedPlaybackID: UUID,
        skippingFailures: Bool,
        from startTime: TimeInterval,
        shouldPlay: Bool
    ) {
        do {
            let engine = resolvedEngine()
            duration = try engine.load(
                songs: queue,
                startingAt: index,
                from: startTime,
                playbackID: requestedPlaybackID
            )
            elapsedTime = startTime
            outputStatus = engine.outputStatus
            if shouldPlay {
                try engine.play()
                state = .playing
                beginListeningSession()
                startProgressUpdates()
            } else {
                state = .paused
            }
        } catch {
            if skippingFailures, index + 1 < queue.count {
                startSong(at: index + 1, skippingFailures: true)
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    private func resume() {
        do {
            guard let engine else {
                return
            }
            try engine.play()
            state = .playing
            beginListeningSession()
            startProgressUpdates()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finishQueue() {
        endListeningSession(completed: true)
        engine?.pause()
        stopProgressUpdates()
        elapsedTime = duration
        state = currentSong == nil ? .idle : .paused
    }

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .started(let startedID, let url, let startedDuration):
            guard startedID == playbackID,
                  let index = queue.firstIndex(where: { $0.url == url }) else {
                return
            }
            let isReloadingCurrentSong = currentIndex == index
            if !isReloadingCurrentSong {
                endListeningSession(completed: true)
            }
            currentIndex = index
            currentSong = queue[index]
            duration = startedDuration
            if !isReloadingCurrentSong {
                elapsedTime = 0
            }
            if let engine {
                outputStatus = engine.outputStatus
            }
            if !isReloadingCurrentSong, state == .playing {
                beginListeningSession()
            }
        case .finished(let completedID):
            guard completedID == playbackID else {
                return
            }
            next()
        case .failed(let message):
            fail(message)
        }
    }

    private func fail(_ message: String) {
        endListeningSession()
        engine?.stop()
        stopProgressUpdates()
        state = .failed(message)
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.state == .playing else {
                    return
                }

                guard let engine = self.engine else {
                    return
                }
                self.elapsedTime = min(engine.currentTime, self.duration)
                if Date().timeIntervalSince(self.lastListeningHeartbeat) >= 5,
                   let sessionID = self.listeningSessionID {
                    self.database.heartbeatListeningSession(id: sessionID)
                    self.lastListeningHeartbeat = Date()
                }
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func resolvedEngine() -> any AudioPlaybackEngine {
        if let engine {
            return engine
        }

        let engine = engineFactory()
        self.engine = engine
        configure(engine)
        return engine
    }

    private func configure(_ engine: any AudioPlaybackEngine) {
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        engine.levelHandler = { [weak self] levels in
            self?.updateVisualizerLevels(with: levels)
        }
        engine.volume = preferences.mode == .bitPerfect ? 1 : Float(volume)
        outputStatus = engine.outputStatus
    }

    private func updateVisualizerLevels(with incomingLevels: [Double]) {
        guard incomingLevels.count == visualizerLevels.count else {
            visualizerLevels = incomingLevels
            return
        }

        if incomingLevels.allSatisfy({ $0 <= 0 }) {
            visualizerLevels = incomingLevels
            return
        }

        visualizerLevels = zip(visualizerLevels, incomingLevels).map {
            current, incoming in
            // Fast attack lets kicks land immediately; slower release keeps
            // the disc breathing instead of snapping inward between buffers.
            let response = incoming > current ? 0.62 : 0.18
            return current + (incoming - current) * response
        }
    }

    private func beginListeningSession() {
        guard listeningSessionID == nil, let currentSong else {
            return
        }
        listeningSessionID = database.beginListeningSession(
            trackID: currentSong.libraryID
        )
        lastListeningHeartbeat = Date()
    }

    private func endListeningSession(completed: Bool = false) {
        guard let listeningSessionID else {
            return
        }
        database.endListeningSession(
            id: listeningSessionID,
            completed: completed
        )
        self.listeningSessionID = nil
        lastListeningHeartbeat = .distantPast
    }
}
