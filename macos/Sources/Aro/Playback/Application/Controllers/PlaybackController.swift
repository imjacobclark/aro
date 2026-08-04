import Foundation
import AroCommon
import Observation
import OSLog

@MainActor
@Observable
final class PlaybackController {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "Playback"
    )
    /// Ticks (at 250ms each) of zero playback progress before a stall is
    /// treated as terminal rather than ordinary buffering. Measured
    /// independent of `isWaitingForData`, since a permanently failed
    /// streaming resource stops reporting itself as waiting once its reader
    /// gives up — without this, playback could sit at `.buffering` forever
    /// with no further signal that anything had gone wrong.
    private static let stallTimeoutTicks = 40
    private static let maxStallRetries = 1

    private(set) var state: PlaybackState = .idle
    private(set) var currentSong: Song?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedFraction: Double = 1
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    private(set) var volume: Double = 1
    private(set) var outputStatus = PlaybackOutputStatus()
    private(set) var visualizerLevels = Array(repeating: 0.0, count: 9)
    private(set) var isShuffleEnabled: Bool
    private(set) var repeatMode: PlaybackRepeatMode
    /// Set by the active library transport. While offline, catalogue entries remain
    /// browsable but queues are reduced to media actually present on this Mac.
    var restrictsPlaybackToLocalMedia = false
    /// A colocated server outage is an infrastructure failure, not permission
    /// to bypass the authority by opening original files directly.
    private(set) var serverUnavailableReason: String?

    @ObservationIgnored private var engine: (any AudioPlaybackEngine)?
    @ObservationIgnored private let engineFactory: @MainActor () -> any AudioPlaybackEngine
    @ObservationIgnored private let preferences: PlaybackPreferences
    @ObservationIgnored private let loudnessService: any LoudnessAnalyzing
    @ObservationIgnored private let listeningSession: ListeningSessionTracker
    @ObservationIgnored private let nowPlayingPublisher: any NowPlayingPublishing
    @ObservationIgnored private let queuePolicy: PlaybackQueuePolicy
    @ObservationIgnored private let visualizerSmoother: VisualizerLevelSmoother
    @ObservationIgnored private let effectiveModeResolver: @MainActor () -> PlaybackMode
    @ObservationIgnored private let prepareSong: PrepareSongForPlayback?
    @ObservationIgnored private let mediaLocationResolver:
        (@MainActor (Song) -> PlaybackMediaLocation?)?
    @ObservationIgnored private let localMediaAvailability:
        @MainActor (Song) -> Bool
    /// Reorders upcoming tracks by measured audio similarity; `nil` when no hub is
    /// available, in which case shuffle stays uniformly random.
    ///
    /// Settable rather than injected at construction because the hub transport is
    /// assembled from view-level state (active profile, discovered local servers)
    /// that `LibraryRuntime` doesn't hold — see `ContentView`, which assigns it.
    @ObservationIgnored var smartShuffleOrder:
        (@MainActor ([String], String?) async -> [String]?)?
    @ObservationIgnored private let progressivePlaybackEligibility:
        @MainActor (Song) -> Bool
    @ObservationIgnored private let progressiveDownloadFallbackAllowed:
        @MainActor () -> Bool
    @ObservationIgnored private var playbackID = UUID()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var progressiveFallbackPlaybackIDs =
        Set<UUID>()
    @ObservationIgnored private var playbackRequestedAt = Date()
    @ObservationIgnored private var firstPCMPlaybackID: UUID?
    @ObservationIgnored private var canonicalQueue: [Song] = []
    @ObservationIgnored private var stallRetryCount = 0

    init(
        engine: (any AudioPlaybackEngine)? = nil,
        preferences: PlaybackPreferences = PlaybackPreferences(),
        loudnessService: any LoudnessAnalyzing = NoOpLoudnessAnalyzer(),
        listeningHistory: any ListeningHistoryRecording =
            NoOpListeningHistoryRecorder(),
        playbackActivity: any PlaybackActivityReporting =
            NoOpPlaybackActivityReporter(),
        nowPlayingPublisher: any NowPlayingPublishing =
            NoOpNowPlayingPublisher(),
        queuePolicy: PlaybackQueuePolicy = PlaybackQueuePolicy(),
        visualizerSmoother: VisualizerLevelSmoother =
            VisualizerLevelSmoother(),
        effectiveModeResolver: (@MainActor () -> PlaybackMode)? = nil,
        prepareSong: PrepareSongForPlayback? = nil,
        mediaLocationResolver:
            (@MainActor (Song) -> PlaybackMediaLocation?)? = nil,
        localMediaAvailability:
            @escaping @MainActor (Song) -> Bool = { $0.url.isFileURL },
        smartShuffleOrder:
            (@MainActor ([String], String?) async -> [String]?)? = nil,
        progressivePlaybackEligibility:
            @escaping @MainActor (Song) -> Bool = { _ in false },
        progressiveDownloadFallbackAllowed:
            @escaping @MainActor () -> Bool = { true },
        engineFactory: @escaping @MainActor () -> any AudioPlaybackEngine = {
            UnavailableAudioPlaybackEngine()
        }
    ) {
        self.engine = engine
        self.preferences = preferences
        isShuffleEnabled = preferences.shuffleEnabled
        repeatMode = preferences.repeatMode
        self.loudnessService = loudnessService
        listeningSession = ListeningSessionTracker(
            history: listeningHistory,
            activity: playbackActivity
        )
        self.nowPlayingPublisher = nowPlayingPublisher
        self.queuePolicy = queuePolicy
        self.visualizerSmoother = visualizerSmoother
        self.effectiveModeResolver = effectiveModeResolver ?? { [preferences] in preferences.mode }
        self.prepareSong = prepareSong
        self.mediaLocationResolver = mediaLocationResolver
        self.localMediaAvailability = localMediaAvailability
        self.smartShuffleOrder = smartShuffleOrder
        self.progressivePlaybackEligibility = progressivePlaybackEligibility
        self.progressiveDownloadFallbackAllowed =
            progressiveDownloadFallbackAllowed
        self.engineFactory = engineFactory

        if let engine {
            configure(engine)
        }
    }

    var isPlaying: Bool {
        state == .playing || state == .buffering
    }

    var canTogglePlayback: Bool {
        currentSong != nil && serverUnavailableReason == nil
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
            || (repeatMode == .all && !queue.isEmpty)
    }

    var errorMessage: String? {
        guard case .failed(let message) = state else {
            return nil
        }
        return message
    }

    func play(song: Song, queue requestedQueue: [Song]) {
        guard serverUnavailableReason == nil else {
            fail(serverUnavailableReason ?? "The library server is unavailable.")
            return
        }
        let playableQueue = restrictsPlaybackToLocalMedia
            ? requestedQueue.filter(localMediaAvailability)
            : requestedQueue
        guard !restrictsPlaybackToLocalMedia || localMediaAvailability(song) else {
            fail("This song has not been downloaded and the library server is offline.")
            return
        }
        let prepared = queuePolicy.prepare(
            selectedSong: song,
            requestedQueue: playableQueue
        )
        canonicalQueue = prepared.songs
        if isShuffleEnabled {
            let remaining = prepared.songs
                .filter { $0.id != song.id }
                .shuffled()
            queue = [song] + remaining
            startSong(at: 0, skippingFailures: false)
            resequenceUpcomingBySimilarity()
        } else {
            queue = prepared.songs
            startSong(at: prepared.selectedIndex, skippingFailures: false)
        }
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        preferences.shuffleEnabled = isShuffleEnabled

        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return
        }
        let played = Array(queue[...currentIndex])
        let playedIDs = Set(played.map(\.id))
        let remaining: [Song]
        if isShuffleEnabled {
            remaining = Array(queue.dropFirst(currentIndex + 1)).shuffled()
        } else {
            remaining = canonicalQueue.filter { !playedIDs.contains($0.id) }
        }
        queue = played + remaining
        restartCurrentSongAfterQueueChange()
        if isShuffleEnabled {
            resequenceUpcomingBySimilarity()
        }
    }

    /// Re-orders the *upcoming* part of a shuffled queue so consecutive tracks sound
    /// alike, leaving already-played tracks and the current one untouched.
    ///
    /// Runs after playback has already started on a uniformly shuffled queue rather
    /// than before it: the ordering needs a hub round trip, and making the listener
    /// wait on the network before hearing anything would be a bad trade for what is
    /// only a sequencing refinement. The audible result is the same, since the change
    /// only ever affects tracks that haven't played yet.
    private func resequenceUpcomingBySimilarity() {
        guard let smartShuffleOrder, isShuffleEnabled else { return }
        let anchorIndex = currentIndex ?? 0
        guard queue.indices.contains(anchorIndex) else { return }
        let upcoming = Array(queue.dropFirst(anchorIndex + 1))
        // Nothing meaningful to sequence, and no point paying for a round trip.
        guard upcoming.count > 1 else { return }

        let anchor = queue[anchorIndex]
        let requestedPlaybackID = playbackID
        let hashes = upcoming.compactMap(\.contentHash)
        guard hashes.count > 1 else { return }

        Task { [weak self] in
            guard let ordered = await smartShuffleOrder(hashes, anchor.contentHash),
                  let self else {
                return
            }
            // The listener may have skipped, re-shuffled, or started something else
            // entirely while this was in flight; applying a stale ordering would
            // yank the queue out from under them.
            guard requestedPlaybackID == self.playbackID,
                  self.isShuffleEnabled,
                  (self.currentIndex ?? 0) == anchorIndex else {
                return
            }
            self.applyUpcomingOrder(ordered, after: anchorIndex)
        }
    }

    /// Rewrites the queue after `anchorIndex` into `orderedHashes` order. Tracks the
    /// hub didn't return (an unanalyzed file, or one it doesn't know) keep their
    /// existing relative order and follow on the end — a shuffle that quietly
    /// dropped tracks would be far worse than one that sequences a few imperfectly.
    private func applyUpcomingOrder(_ orderedHashes: [String], after anchorIndex: Int) {
        guard queue.indices.contains(anchorIndex) else { return }
        let upcoming = Array(queue.dropFirst(anchorIndex + 1))
        var byHash: [String: [Song]] = [:]
        for song in upcoming {
            guard let hash = song.contentHash else { continue }
            byHash[hash, default: []].append(song)
        }
        var reordered: [Song] = []
        var placed = Set<Song.ID>()
        for hash in orderedHashes {
            guard var bucket = byHash[hash], !bucket.isEmpty else { continue }
            let song = bucket.removeFirst()
            byHash[hash] = bucket
            reordered.append(song)
            placed.insert(song.id)
        }
        reordered.append(contentsOf: upcoming.filter { !placed.contains($0.id) })
        guard reordered.count == upcoming.count else { return }
        queue = Array(queue[...anchorIndex]) + reordered
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        preferences.repeatMode = repeatMode

        // The engine normally pre-enqueues a compatible run. Entering
        // repeat-one reloads the current song at the same position so no
        // already-enqueued successor can bypass the new mode.
        if repeatMode == .one {
            restartCurrentSongAfterQueueChange()
        }
    }

    func playQueuedSong(at index: Int) {
        guard queue.indices.contains(index) else { return }
        startSong(at: index, skippingFailures: false)
    }

    func togglePlayPause() {
        guard serverUnavailableReason == nil else {
            fail(serverUnavailableReason ?? "The library server is unavailable.")
            return
        }
        switch state {
        case .playing, .buffering:
            guard let engine else {
                return
            }
            listeningSession.end()
            engine.pause()
            elapsedTime = engine.currentTime
            state = .paused
            stopProgressUpdates()
            publishNowPlayingInfo()
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

    func setServerUnavailable(_ reason: String?) {
        guard serverUnavailableReason != reason else { return }
        serverUnavailableReason = reason
        guard let reason else { return }
        preparationTask?.cancel()
        engine?.stop()
        listeningSession.end()
        stopProgressUpdates()
        state = .failed(reason)
        publishNowPlayingInfo()
    }

    func previous() {
        guard currentSong != nil else {
            return
        }

        if elapsedTime > 3 || (currentIndex ?? 0) == 0 {
            seek(to: 0)
            return
        }

        guard let currentIndex else {
            return
        }
        if currentIndex > 0 {
            startSong(at: currentIndex - 1, skippingFailures: true)
        } else if repeatMode == .all, !queue.isEmpty {
            startSong(at: queue.count - 1, skippingFailures: true)
        }
    }

    func next() {
        guard let currentIndex else {
            return
        }
        if currentIndex + 1 < queue.count {
            startSong(at: currentIndex + 1, skippingFailures: true)
        } else if repeatMode == .all, !queue.isEmpty {
            startSong(at: 0, skippingFailures: true)
        } else {
            finishQueue()
        }
    }

    func seek(to requestedTime: TimeInterval) {
        guard currentSong != nil, duration > 0 else {
            return
        }

        let clampedTime = min(max(requestedTime, 0), duration)
        let shouldPlay = state == .playing || state == .buffering
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
            publishNowPlayingInfo()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func setVolume(_ requestedVolume: Double) {
        volume = effectiveModeResolver() == .bitPerfect
            ? 1
            : min(max(requestedVolume, 0), 1)
        engine?.volume = Float(volume)
    }

    func refreshNormalizedGain() {
        guard effectiveModeResolver() == .normalized, let engine else {
            return
        }
        engine.volume = Float(volume)
        outputStatus = engine.outputStatus
    }

    func restartForPlaybackSettingsChange() {
        setVolume(volume)
        guard currentSong != nil, let currentIndex else {
            return
        }
        let restartTime = elapsedTime
        let shouldResume =
            state == .playing || state == .buffering || state == .loading
        startSong(
            at: currentIndex,
            skippingFailures: false,
            from: restartTime,
            shouldPlay: shouldResume
        )
    }

    func reconcileAvailableSongs(_ availableSongs: [Song]) {
        let reconciled = queuePolicy.reconcile(
            queue: queue,
            currentSong: currentSong,
            availableSongs: availableSongs
        )
        queue = reconciled.songs
        let availableByID = Dictionary(
            uniqueKeysWithValues: availableSongs.map { ($0.id, $0) }
        )
        canonicalQueue = canonicalQueue.compactMap {
            availableByID[$0.id]
        }

        guard currentSong != nil else {
            return
        }

        guard let updatedSong = reconciled.currentSong else {
            stopAndClear()
            return
        }

        self.currentSong = updatedSong
        currentIndex = reconciled.currentIndex
    }

    func stopAndClear() {
        listeningSession.end()
        engine?.stop()
        stopProgressUpdates()
        preparationTask?.cancel()
        preparationTask = nil
        playbackID = UUID()
        progressiveFallbackPlaybackIDs.removeAll()
        state = .idle
        currentSong = nil
        elapsedTime = 0
        duration = 0
        bufferedFraction = 1
        queue = []
        canonicalQueue = []
        currentIndex = nil
        visualizerLevels = Array(repeating: 0, count: 9)
        publishNowPlayingInfo()
    }

    private func startSong(
        at index: Int,
        skippingFailures: Bool,
        from requestedTime: TimeInterval = 0,
        shouldPlay: Bool = true,
        isStallRetry: Bool = false
    ) {
        guard serverUnavailableReason == nil else {
            fail(serverUnavailableReason ?? "The library server is unavailable.")
            return
        }
        guard queue.indices.contains(index) else {
            finishQueue()
            return
        }
        if !isStallRetry {
            stallRetryCount = 0
        }

        // A deliberate move to a *different* song while the current one was still
        // early (under 30s, or under half its length) is a real "skipped" signal for
        // Tier 1 behavioural playlists — distinct from a same-song reload (queue
        // reconciliation, a playback-settings change, a stall retry), which restarts
        // the exact song at `currentIndex` and isn't the user moving on from
        // anything. Computed here, before `duration`/`elapsedTime` below are
        // overwritten with the *new* song's values.
        if !isStallRetry, let currentIndex, currentIndex != index, duration > 0 {
            let wasSkipped = elapsedTime < min(30, duration / 2)
            listeningSession.end(skipped: wasSkipped)
        } else {
            listeningSession.end()
        }
        stopProgressUpdates()
        preparationTask?.cancel()
        preparationTask = nil
        state = .loading
        currentIndex = index
        currentSong = queue[index]
        duration = queue[index].duration ?? 0
        let startTime = min(max(requestedTime, 0), duration)
        elapsedTime = startTime
        bufferedFraction = queue[index].url.isFileURL ? 1 : 0
        playbackID = UUID()
        playbackRequestedAt = Date()
        firstPCMPlaybackID = nil
        let requestedPlaybackID = playbackID
        progressiveFallbackPlaybackIDs.removeAll()

        if let prepareSong,
           let location = mediaLocationResolver?(queue[index]),
           !shouldProgressivelyStream(queue[index], location: location) {
            preparationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let localURL = try await prepareSong.execute(location)
                    guard !Task.isCancelled,
                          requestedPlaybackID == self.playbackID else {
                        return
                    }
                    let prepared = self.queue[index].replacingURL(localURL)
                    self.queue[index] = prepared
                    self.currentSong = prepared
                    await self.prepareLoudnessAndStart(
                        at: index,
                        playbackID: requestedPlaybackID,
                        skippingFailures: skippingFailures,
                        from: startTime,
                        shouldPlay: shouldPlay
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self.fail(error.localizedDescription)
                }
                self.preparationTask = nil
            }
            return
        }

        startPreparedSong(
            at: index,
            playbackID: requestedPlaybackID,
            skippingFailures: skippingFailures,
            from: startTime,
            shouldPlay: shouldPlay
        )
    }

    private func prepareLoudnessAndStart(
        at index: Int,
        playbackID requestedPlaybackID: UUID,
        skippingFailures: Bool,
        from startTime: TimeInterval,
        shouldPlay: Bool
    ) async {
        if effectiveModeResolver() == .normalized {
            await prepareLoudnessRun(
                startingAt: index,
                playbackID: requestedPlaybackID
            )
        }
        guard !Task.isCancelled,
              requestedPlaybackID == playbackID else {
            return
        }
        startPreparedSong(
            at: index,
            playbackID: requestedPlaybackID,
            skippingFailures: skippingFailures,
            from: startTime,
            shouldPlay: shouldPlay
        )
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
            let decoderQueue = playbackItemRun(startingAt: index)
            guard !decoderQueue.isEmpty else {
                throw PrepareSongError.missingLocalFile
            }
            let engine = resolvedEngine()
            duration = try engine.load(
                items: decoderQueue,
                startingAt: 0,
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
            publishNowPlayingInfo()
        } catch {
            if case .progressiveStreamingFailed(let message) = error
                    as? PlaybackEngineError,
               beginProgressiveFallback(
                    at: index,
                    playbackID: requestedPlaybackID,
                    from: startTime,
                    shouldPlay: shouldPlay,
                    streamingMessage: message
               ) {
                return
            }
            if skippingFailures, index + 1 < queue.count {
                startSong(at: index + 1, skippingFailures: true)
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    private func playbackItemRun(
        startingAt index: Int
    ) -> [PlaybackQueueItem] {
        guard queue.indices.contains(index) else { return [] }
        var result: [PlaybackQueueItem] = []
        for song in queue[index...] {
            // Once a remote item has been downloaded/verified, `replacingURL`
            // makes its URL local. Never ask the remote resolver to reinterpret
            // that prepared copy as another network resource.
            let location = song.url.isFileURL
                ? .local(song.url)
                : mediaLocationResolver?(song)
            guard let location else {
                break
            }
            if case .remote = location,
               !shouldProgressivelyStream(song, location: location) {
                break
            }
            result.append(
                PlaybackQueueItem(song: song, location: location)
            )
            if repeatMode == .one {
                break
            }
        }
        return result
    }

    private func shouldProgressivelyStream(
        _ song: Song,
        location: PlaybackMediaLocation
    ) -> Bool {
        guard case .remote = location,
              progressivePlaybackEligibility(song) else {
            return false
        }
        return true
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
            publishNowPlayingInfo()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finishQueue() {
        listeningSession.end(completed: true)
        engine?.pause()
        stopProgressUpdates()
        elapsedTime = duration
        state = currentSong == nil ? .idle : .paused
        publishNowPlayingInfo()
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
                listeningSession.end(completed: true)
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
            let decoderMilliseconds = Int(
                Date().timeIntervalSince(playbackRequestedAt) * 1_000
            )
            Self.logger.info(
                "Decoder started after \(decoderMilliseconds, privacy: .public) ms"
            )
            if !isReloadingCurrentSong,
               state == .playing || state == .buffering {
                beginListeningSession()
            }
            publishNowPlayingInfo()
        case .finished(let completedID):
            guard completedID == playbackID else {
                return
            }
            if repeatMode == .one, let currentIndex {
                startSong(at: currentIndex, skippingFailures: false)
            } else {
                next()
            }
        case .failed(let message):
            fail(message)
        case .progressiveStreamingFailed(let failedID, let message):
            guard failedID == playbackID,
                  let currentIndex else {
                return
            }
            guard !progressiveFallbackPlaybackIDs.contains(failedID) else {
                return
            }
            let resumeTime = max(
                elapsedTime,
                min(engine?.currentTime ?? elapsedTime, duration)
            )
            let shouldPlay = state == .playing
                || state == .buffering
                || state == .loading
            if !beginProgressiveFallback(
                at: currentIndex,
                playbackID: failedID,
                from: resumeTime,
                shouldPlay: shouldPlay,
                streamingMessage: message
            ) {
                fail(message)
            }
        }
    }

    @discardableResult
    private func beginProgressiveFallback(
        at index: Int,
        playbackID requestedPlaybackID: UUID,
        from requestedTime: TimeInterval,
        shouldPlay: Bool,
        streamingMessage: String
    ) -> Bool {
        guard requestedPlaybackID == playbackID,
              queue.indices.contains(index),
              !progressiveFallbackPlaybackIDs.contains(requestedPlaybackID),
              progressiveDownloadFallbackAllowed(),
              let prepareSong,
              let location = mediaLocationResolver?(queue[index]),
              case .remote = location else {
            return false
        }

        progressiveFallbackPlaybackIDs.insert(requestedPlaybackID)
        Self.logger.warning(
            "Progressive playback failed; downloading verified song instead: \(streamingMessage, privacy: .public)"
        )
        listeningSession.end()
        engine?.stop()
        stopProgressUpdates()
        preparationTask?.cancel()
        state = .loading
        elapsedTime = min(max(requestedTime, 0), duration)

        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let localURL = try await prepareSong.execute(location)
                guard !Task.isCancelled,
                      requestedPlaybackID == self.playbackID,
                      self.queue.indices.contains(index) else {
                    return
                }
                let prepared = self.queue[index].replacingURL(localURL)
                self.queue[index] = prepared
                self.currentSong = prepared
                self.bufferedFraction = 1
                Self.logger.info(
                    "Verified download fallback completed"
                )
                await self.prepareLoudnessAndStart(
                    at: index,
                    playbackID: requestedPlaybackID,
                    skippingFailures: false,
                    from: self.elapsedTime,
                    shouldPlay: shouldPlay
                )
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Verified download fallback failed: \(error.localizedDescription, privacy: .public)"
                )
                self.fail(
                    "Streaming failed: \(streamingMessage) Download fallback failed: \(error.localizedDescription)"
                )
            }
            self.preparationTask = nil
        }
        return true
    }

    private func fail(_ message: String) {
        listeningSession.end()
        engine?.stop()
        stopProgressUpdates()
        state = .failed(message)
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { [weak self] in
            var stationaryTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self,
                      self.state == .playing || self.state == .buffering else {
                    return
                }

                guard let engine = self.engine else {
                    return
                }
                let updatedTime = min(engine.currentTime, self.duration)
                if updatedTime > self.elapsedTime + 0.01 {
                    stationaryTicks = 0
                    self.stallRetryCount = 0
                    if self.state == .buffering {
                        self.state = .playing
                    }
                } else {
                    // Tracked regardless of `isWaitingForData`: a streaming
                    // resource that has permanently failed stops reporting
                    // itself as waiting once its reader gives up, so relying
                    // on that flag alone would let a stall go undetected.
                    stationaryTicks += 1
                    if engine.isWaitingForData, stationaryTicks >= 4 {
                        self.state = .buffering
                    }
                    if stationaryTicks >= Self.stallTimeoutTicks {
                        self.handleStall()
                        return
                    }
                }
                self.elapsedTime = updatedTime
                self.bufferedFraction = engine.bufferedFraction
                self.listeningSession.heartbeatIfNeeded(
                    position: self.elapsedTime,
                    duration: self.duration,
                    bufferedFraction: self.bufferedFraction,
                    buffering: self.state == .buffering,
                    outputStatus: self.outputStatus
                )
            }
        }
    }

    /// Called after `stallTimeoutTicks` (10s) of zero playback progress.
    /// Retries once from the current position — enough to recover from a
    /// transient network hiccup — then surfaces a clear failure instead of
    /// leaving playback stuck at "Buffering" indefinitely.
    private func handleStall() {
        guard let currentIndex else {
            fail("Playback stalled. Check your connection and try again.")
            return
        }
        guard stallRetryCount < Self.maxStallRetries else {
            Self.logger.error(
                "Playback stalled with no progress and no fix after retrying"
            )
            fail("Playback stalled. Check your connection and try again.")
            return
        }
        stallRetryCount += 1
        Self.logger.warning(
            "Playback stalled with no progress; retrying from \(self.elapsedTime, privacy: .public)s"
        )
        startSong(
            at: currentIndex,
            skippingFailures: false,
            from: elapsedTime,
            shouldPlay: true,
            isStallRetry: true
        )
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
        engine.volume = effectiveModeResolver() == .bitPerfect ? 1 : Float(volume)
        outputStatus = engine.outputStatus
    }

    private func updateVisualizerLevels(with incomingLevels: [Double]) {
        if firstPCMPlaybackID != playbackID,
           incomingLevels.contains(where: { $0 > 0.000_1 }) {
            firstPCMPlaybackID = playbackID
            let pcmMilliseconds = Int(
                Date().timeIntervalSince(playbackRequestedAt) * 1_000
            )
            Self.logger.info(
                "First rendered PCM after \(pcmMilliseconds, privacy: .public) ms"
            )
        }
        visualizerLevels = visualizerSmoother.update(
            current: visualizerLevels,
            incoming: incomingLevels
        )
    }

    private func publishNowPlayingInfo() {
        nowPlayingPublisher.publish(
            song: currentSong,
            elapsedTime: elapsedTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private func beginListeningSession() {
        guard let currentSong else {
            return
        }
        listeningSession.begin(
            trackID: currentSong.libraryID,
            contentHash: currentSong.contentHash,
            outputStatus: outputStatus
        )
    }

    private func restartCurrentSongAfterQueueChange() {
        guard currentSong != nil, let currentIndex else { return }
        let restartTime = elapsedTime
        let shouldResume =
            state == .playing || state == .buffering || state == .loading
        startSong(
            at: currentIndex,
            skippingFailures: false,
            from: restartTime,
            shouldPlay: shouldResume
        )
    }
}
