import AVFAudio
import AroCommon
import AroStreamingInput
import Foundation
import OSLog
import SFBAudioEngine

/// SFBAudioEngine reconfigures its source node on the decoder thread after it
/// discovers the track's real PCM format. Keep the inserted normalization
/// node available to that callback without inheriting `MainActor`.
private final class NormalizationProcessingGraphState: @unchecked Sendable {
    private let lock = NSLock()
    private var node: AVAudioUnitEQ?

    func setNode(_ node: AVAudioUnitEQ?) {
        lock.withLock {
            self.node = node
        }
    }

    func reconfigure(
        engine: AVAudioEngine,
        format: AVAudioFormat
    ) -> AVAudioNode {
        lock.withLock {
            guard let node else {
                return engine.mainMixerNode
            }
            engine.disconnectNodeOutput(node)
            engine.connect(
                node,
                to: engine.mainMixerNode,
                format: format
            )
            return node
        }
    }
}

@MainActor
final class HighResolutionPlaybackEngine: NSObject, AudioPlaybackEngine {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "ProgressivePlayback"
    )

    var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) -> Void)?
    var levelHandler: (@MainActor @Sendable ([Double]) -> Void)?

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    var volume: Float {
        get { requestedVolume }
        set {
            requestedVolume = min(max(newValue, 0), 1)
            applyGain(for: currentSong)
        }
    }

    var bufferedFraction: Double {
        guard let url = currentSong?.url,
              let resource = resourcesByURL[url] else {
            return 1
        }
        return resource.bufferedFraction
    }

    var isWaitingForData: Bool {
        guard let url = currentSong?.url else { return false }
        return resourcesByURL[url]?.isWaitingForData ?? false
    }

    private(set) var outputStatus = PlaybackOutputStatus()

    private var player: SFBAudioEngine.AudioPlayer?
    private var normalizationNode: AVAudioUnitEQ?
    private let preferences: PlaybackPreferences
    private let deviceManager: any AudioDeviceManaging
    private let streamingCoordinator: ProgressiveMediaCoordinator?
    private nonisolated let normalizationGraphState =
        NormalizationProcessingGraphState()
    private var songs: [Song] = []
    private var playbackItems: [PlaybackQueueItem] = []
    private var indicesByURL: [URL: Int] = [:]
    private var resourcesByURL: [URL: ProgressiveMediaResource] = [:]
    private var currentSong: Song?
    private var activePlaybackID: UUID?
    private var selectedDevice: AudioOutputDevice?
    private var configuredSampleRate: Double?
    private var configuredHogModeRequested = false
    private var requestedVolume: Float = 1
    private var normalizationGraphIsActive = false
    private var effectiveMode: PlaybackMode = .bitPerfect
    private var meterTapIsInstalled = false
    private var meterRelay: AudioMeterRelay?

    init(
        preferences: PlaybackPreferences,
        deviceManager: any AudioDeviceManaging,
        streamingCoordinator: ProgressiveMediaCoordinator? = nil
    ) {
        self.preferences = preferences
        self.deviceManager = deviceManager
        self.streamingCoordinator = streamingCoordinator
        super.init()
    }

    func load(
        items: [PlaybackQueueItem],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval {
        guard items.indices.contains(index) else {
            throw PlaybackEngineError.invalidAudioFile
        }

        let songs = items.map(\.song)
        let firstSong = songs[index]
        guard let properties = firstSong.audioProperties,
              let sampleRate = properties.sampleRate,
              sampleRate > 0 else {
            stop()
            throw PlaybackEngineError.missingAudioProperties
        }

        let device = deviceManager.selectedDevice(
            for: preferences.outputDeviceUID
        )
        var routeFallbackWarning: String?
        if let device, let storedUID = preferences.outputDeviceUID,
           device.uid != storedUID {
            routeFallbackWarning =
                "The previously selected output device is no longer available. Using \(device.name) instead."
            preferences.outputDeviceUID = nil
        }
        let nextEffectiveMode = PlaybackRoutePolicy().effectiveMode(
            preferredMode: preferences.mode,
            device: device
        )
        if let gateError = PlaybackRoutePolicy().loudnessGateError(
            effectiveMode: nextEffectiveMode,
            leadSongLoudness: firstSong.loudness
        ) {
            stop()
            throw gateError
        }
        var outputSampleRate = sampleRate
        if let device {
            if device.transport.isWireless {
                outputSampleRate = deviceManager.nominalSampleRate(for: device) ?? sampleRate
            } else if nextEffectiveMode == .normalized,
               !device.supports(sampleRate: sampleRate) {
                outputSampleRate = deviceManager.nominalSampleRate(for: device)
                    .flatMap { device.supports(sampleRate: $0) ? $0 : nil }
                    ?? device.nearestSupportedSampleRate(to: sampleRate)
                    ?? sampleRate
            }
        }
        let shouldAcquireHogMode = device.map {
            preferences.hogModeEnabled
                && PlaybackRoutePolicy().allowsExclusiveAccess(for: $0)
        } ?? false
        let reusesDeviceConfiguration = canReuseDeviceConfiguration(
            device: device,
            sampleRate: outputSampleRate,
            acquireHogMode: shouldAcquireHogMode
        )

        // A song selection rebuilds SFBAudioEngine's decoder graph, but it
        // must not bounce the hardware back to its pre-playback sample rate
        // and immediately configure it again. Those two asynchronous Core
        // Audio format changes can reach the newly-created AVAudioEngine and
        // make its first allocation fail with kAudioUnitErr_InvalidPropertyValue
        // (-10851). Retain the device lease when the route, rate, and exclusive
        // access request are unchanged; a real stop or incompatible reload
        // still restores the hardware.
        resetPlayback(
            releasingDeviceConfiguration: !reusesDeviceConfiguration
        )

        do {
            self.songs = songs
            playbackItems = items
            activePlaybackID = playbackID
            effectiveMode = nextEffectiveMode

            if let device {
                if !reusesDeviceConfiguration {
                    let acquiredHog = try deviceManager.configure(
                        device: device,
                        sampleRate: outputSampleRate,
                        acquireHogMode: shouldAcquireHogMode
                    )
                    outputStatus.isExclusive = acquiredHog
                    configuredSampleRate = outputSampleRate
                    configuredHogModeRequested = shouldAcquireHogMode
                }
                selectedDevice = device
            } else {
                outputStatus.isExclusive = false
            }

            // Hardware sample-rate changes post an asynchronous AVAudioEngine
            // configuration notification. Constructing the player only after
            // the device has been configured prevents SFBAudioEngine from
            // observing Core Audio's transient 0 Hz/0-channel format.
            let player = SFBAudioEngine.AudioPlayer()
            player.delegate = self
            self.player = player
            // AVAudioUnitEQ is documented and exercised as a bank of EQ bands.
            // Keep one bypassed band for globalGain rather than relying on the
            // Audio Unit accepting an empty bank across repeated lifecycles.
            let normalizationNode = AVAudioUnitEQ(numberOfBands: 1)
            normalizationNode.bands[0].bypass = true
            self.normalizationNode = normalizationNode
            normalizationGraphState.setNode(normalizationNode)
            // Always set the device, never conditionally. Setting it only when it differed
            // meant that whenever the chosen device happened to already be the default, the
            // audio unit was left in its own follow-the-default state while Aro believed it
            // had pinned a route — so Aro was sometimes a follower and sometimes a pinner,
            // and which one depended on unrelated circumstance.
            if let device {
                try player.setOutputDeviceID(device.id)
            }
            if let device {
                try verifyOutputRouting(
                    player: player,
                    requestedDevice: device
                )
                if device.transport.isWireless {
                    scheduleWirelessRoutingRecheck(playbackID: playbackID)
                }
            }

            outputStatus.mode = effectiveMode
            outputStatus.transport = device?.transport ?? .other
            outputStatus.sourceCodec = properties.codec
            outputStatus.sourceSampleRate = sampleRate
            outputStatus.sourceBitDepth = properties.bitDepth
            outputStatus.sourceChannelCount = properties.channelCount
            outputStatus.sampleRate = outputSampleRate
            outputStatus.bitDepth = properties.bitDepth
            outputStatus.warning =
                routeFallbackWarning ?? deviceManager.lastWarning
            configureProcessingGraph(for: effectiveMode)
            installMeterTap()

            let compatibleItems = compatibleRun(
                in: items,
                startingAt: index
            )
            guard let first = compatibleItems.first else {
                throw PlaybackEngineError.invalidAudioFile
            }

            self.songs = songs
            indicesByURL = Dictionary(
                uniqueKeysWithValues: compatibleItems.map {
                    (playbackURL(for: $0.element), $0.offset)
                }
            )
            currentSong = first.element.song
            applyGain(for: first.element.song)
            streamingCoordinator?.prepareQueue(items)

            try enqueue(first.element, in: player, immediate: true)
            for queued in compatibleItems.dropFirst() {
                try enqueue(queued.element, in: player, immediate: false)
            }

            if time > 0 {
                _ = player.seek(time: time)
            }

            return first.element.song.duration ?? 0
        } catch {
            // `configure` may already have acquired exclusive access. Every
            // failure after that point must tear down the player, release hog
            // mode, and restore the device's previous nominal sample rate.
            stop()
            throw error
        }
    }

    func play() throws {
        guard let player else {
            throw PlaybackEngineError.invalidAudioFile
        }
        if let selectedDevice {
            try verifyOutputRouting(
                player: player,
                requestedDevice: selectedDevice
            )
        }
        do {
            try player.play()
        } catch {
            throw PlaybackEngineError.engineFailedToStart(
                error.localizedDescription
            )
        }
    }

    func pause() {
        _ = player?.pause()
        levelHandler?(Self.silentMeterLevels)
    }

    func seek(
        to time: TimeInterval,
        playbackID: UUID,
        shouldPlay: Bool
    ) throws {
        activePlaybackID = playbackID
        guard let player, player.seek(time: time) else {
            throw PlaybackEngineError.invalidAudioFile
        }
        if shouldPlay {
            try play()
        }
    }

    func stop() {
        resetPlayback(releasingDeviceConfiguration: true)
    }

    private func resetPlayback(
        releasingDeviceConfiguration: Bool
    ) {
        activePlaybackID = nil
        streamingCoordinator?.cancelResources(notIn: [])
        discardPlayer()
        if releasingDeviceConfiguration {
            deviceManager.releaseHogMode(for: selectedDevice)
            selectedDevice = nil
            configuredSampleRate = nil
            configuredHogModeRequested = false
            outputStatus.isExclusive = false
        }
        songs = []
        playbackItems = []
        indicesByURL = [:]
        resourcesByURL = [:]
        currentSong = nil
        levelHandler?(Self.silentMeterLevels)
    }

    private func canReuseDeviceConfiguration(
        device: AudioOutputDevice?,
        sampleRate: Double,
        acquireHogMode: Bool
    ) -> Bool {
        guard let device,
              let selectedDevice,
              selectedDevice.uid == device.uid,
              let configuredSampleRate,
              abs(configuredSampleRate - sampleRate) < 0.5,
              configuredHogModeRequested == acquireHogMode,
              let currentSampleRate = deviceManager.nominalSampleRate(
                for: device
              ),
              abs(currentSampleRate - sampleRate) < 0.5 else {
            return false
        }
        return true
    }

    private func compatibleRun(
        in items: [PlaybackQueueItem],
        startingAt index: Int
    ) -> [(offset: Int, element: PlaybackQueueItem)] {
        let first = items[index].song
        let sampleRate = first.audioProperties?.sampleRate
        let channelCount = first.audioProperties?.channelCount
        var result: [(offset: Int, element: PlaybackQueueItem)] = []

        for candidateIndex in index..<items.count {
            let item = items[candidateIndex]
            let song = item.song
            guard canDecode(item),
                  song.audioProperties?.sampleRate == sampleRate,
                  song.audioProperties?.channelCount == channelCount else {
                break
            }
            if effectiveMode == .normalized, song.loudness == nil {
                break
            }
            result.append((candidateIndex, item))
        }
        return result
    }

    private func canDecode(_ item: PlaybackQueueItem) -> Bool {
        switch item.location {
        case .local(let url):
            return FileManager.default.isReadableFile(atPath: url.path)
        case .remote:
            return streamingCoordinator != nil
                && decoderName(for: item.song) != nil
        }
    }

    private func enqueue(
        _ item: PlaybackQueueItem,
        in player: SFBAudioEngine.AudioPlayer,
        immediate: Bool
    ) throws {
        switch item.location {
        case .local(let url):
            try player.enqueue(url, immediate: immediate)
        case .remote(let media):
            guard let streamingCoordinator,
                  let decoderName = decoderName(for: item.song) else {
                throw PlaybackEngineError.invalidAudioFile
            }
            let resource = try streamingCoordinator.resource(for: media)
            guard let resourcePlaybackID = activePlaybackID else {
                throw PlaybackEngineError.invalidAudioFile
            }
            resource.onIntegrityFailure { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activePlaybackID == resourcePlaybackID else {
                        return
                    }
                    self.eventHandler?(
                        .progressiveStreamingFailed(
                            resourcePlaybackID,
                            message
                        )
                    )
                }
            }
            resourcesByURL[item.song.url] = resource
            let source = Self.makeStreamingInputSource(
                url: item.song.url,
                length: media.byteCount,
                resource: resource
            )
            let decoder: SFBAudioEngine.AudioDecoder
            do {
                decoder = try StreamingInputSource.decoder(
                    inputSource: source,
                    kind: decoderName
                )
            } catch {
                Self.logger.error(
                    "Stream decoder creation failed for codec \(item.song.audioProperties?.codec ?? "unknown", privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                throw PlaybackEngineError.progressiveStreamingFailed(
                    error.localizedDescription
                )
            }
            try player.enqueue(decoder, immediate: immediate)
        }
    }

    /// The decoder invokes this block from its own worker thread. Building the
    /// closure in an explicitly nonisolated context prevents Swift from
    /// inheriting `MainActor` from `enqueue`, which would trap when Core Audio
    /// performs its first callback read.
    nonisolated private static func makeStreamingInputSource(
        url: URL,
        length: Int64,
        resource: ProgressiveMediaResource
    ) -> StreamingInputSource {
        StreamingInputSource(
            url: url,
            length: length
        ) { [weak resource] offset, requestedLength in
            resource?.read(
                offset: offset,
                length: Int(requestedLength)
            )
        }
    }

    private func playbackURL(for item: PlaybackQueueItem) -> URL {
        switch item.location {
        case .local(let url):
            url
        case .remote:
            item.song.url
        }
    }

    private func decoderName(
        for song: Song
    ) -> StreamingDecoderKind? {
        let codec = song.audioProperties?.codec.lowercased() ?? ""
        switch codec {
        case "flac":
            return .FLAC
        case "ogg", "oga", "vorbis", "ogg vorbis":
            return .oggVorbis
        case "mp3", "mpeg", "mpeg-1 layer 3":
            // SFBAudioEngine's mpg123 decoder scans the complete input when
            // opened as seekable. Core Audio uses targeted callbacks instead,
            // preserving progressive startup and seeking.
            return .coreAudio
        case "m4a", "mp4", "aac", "alac", "apple lossless",
             "wav", "wave", "aif", "aiff":
            return .coreAudio
        default:
            return nil
        }
    }

    private static let missingLoudnessWarning = PlaybackEngineError
        .missingLoudnessAnalysis.localizedDescription
    private static let belowUnityGainWarningPrefix =
        "Core Audio reports the output below unity gain"

    private func applyGain(for song: Song?) {
        let gainDecibels: Double
        if effectiveMode == .normalized {
            // A track with no loudness analysis can't be *normalised*, but the listener's
            // volume must still apply. Returning early here left `globalGain` at whatever
            // the previous track set, so the slider moved and nothing happened — only the
            // normalisation term needs the analysis, so drop that term and carry on.
            if let loudness = song?.loudness {
                if outputStatus.warning == Self.missingLoudnessWarning {
                    outputStatus.warning = nil
                }
                gainDecibels = loudness.safeGainDecibels(
                    targetLUFS: preferences.targetLUFS
                )
            } else {
                outputStatus.warning = Self.missingLoudnessWarning
                gainDecibels = 0
            }
        } else {
            if outputStatus.warning == Self.missingLoudnessWarning {
                outputStatus.warning = nil
            }
            gainDecibels = 0
        }

        let userGainDecibels: Double
        if effectiveMode == .bitPerfect {
            userGainDecibels = 0
        } else if requestedVolume > 0 {
            userGainDecibels = 20 * log10(Double(requestedVolume))
        } else {
            userGainDecibels = -96
        }

        normalizationNode?.globalGain = Float(
            min(max(gainDecibels + userGainDecibels, -96), 24)
        )
        // Unity is asserted on the output unit only in bit-perfect, where any attenuation
        // would break the exactness the mode exists to provide. Doing it unconditionally
        // meant Aro overrode per-app volume set from outside the app on every gain change,
        // and then blamed the device — the parameter being reset here is the audio unit's
        // own gain, not the device level shown in Audio MIDI Setup.
        if let player, effectiveMode == .bitPerfect {
            do {
                try player.setVolume(1)
                let actualVolume = player.volume
                if actualVolume.isFinite, actualVolume < 0.999 {
                    outputStatus.warning =
                        "\(Self.belowUnityGainWarningPrefix) (\(Int(actualVolume * 100))%), so output is not bit-exact. Something outside Aro is attenuating this app."
                } else if outputStatus.warning?.hasPrefix(
                    Self.belowUnityGainWarningPrefix
                ) == true {
                    outputStatus.warning = nil
                }
            } catch {
                outputStatus.warning =
                    "Core Audio could not set unity output gain: \(error.localizedDescription)"
            }
        }
        outputStatus.appliedGainDecibels = gainDecibels
    }

    private func configureProcessingGraph(for mode: PlaybackMode) {
        guard mode == .normalized || normalizationGraphIsActive else {
            return
        }
        guard let player, let normalizationNode else {
            return
        }

        player.modifyProcessingGraph { [player, normalizationNode] engine in
            engine.disconnectNodeOutput(player.sourceNode)
            let normalizationNodeIsAttached = engine.attachedNodes.contains(
                normalizationNode
            )
            if normalizationNodeIsAttached {
                engine.disconnectNodeOutput(normalizationNode)
            }

            switch mode {
            case .normalized:
                if !normalizationNodeIsAttached {
                    engine.attach(normalizationNode)
                }
                let sourceFormat = player.sourceNode.outputFormat(forBus: 0)
                engine.connect(
                    player.sourceNode,
                    to: normalizationNode,
                    format: sourceFormat
                )
                engine.connect(
                    normalizationNode,
                    to: player.mainMixerNode,
                    format: sourceFormat
                )
            case .bitPerfect:
                if normalizationNodeIsAttached {
                    engine.detach(normalizationNode)
                }
                engine.connect(
                    player.sourceNode,
                    to: player.mainMixerNode,
                    format: nil
                )
            }
        }
        normalizationGraphIsActive = mode == .normalized
    }

    private func discardPlayer() {
        meterRelay?.invalidate()
        if meterTapIsInstalled, let player {
            player.modifyProcessingGraph { engine in
                engine.mainMixerNode.removeTap(onBus: 0)
            }
        }
        meterTapIsInstalled = false
        meterRelay = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        normalizationNode = nil
        normalizationGraphState.setNode(nil)
        normalizationGraphIsActive = false
    }

    private func installMeterTap() {
        guard let player, !meterTapIsInstalled else {
            return
        }

        let relay = AudioMeterRelay { [weak self] levels in
            self?.levelHandler?(levels)
        }
        meterRelay = relay
        let tapBlock = makeAudioMeterTapBlock(relay: relay)

        player.modifyProcessingGraph { engine in
            engine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: nil,
                block: tapBlock
            )
        }
        meterTapIsInstalled = true
    }

    private static let silentMeterLevels = Array(
        repeating: 0.0,
        count: 9
    )

    private func verifyOutputRouting(
        player: SFBAudioEngine.AudioPlayer,
        requestedDevice: AudioOutputDevice
    ) throws {
        let actualDeviceID = player.outputDeviceID
        let actualName = deviceManager.device(withID: actualDeviceID)?.name
            ?? "an unknown device"
        outputStatus.deviceName = actualName

        guard actualDeviceID == requestedDevice.id else {
            let error = PlaybackEngineError.outputDeviceMismatch(
                requested: requestedDevice.name,
                actual: actualName
            )
            outputStatus.warning = error.localizedDescription
            throw error
        }
    }

    /// Re-checks the output route and, if the hardware has drifted back to a
    /// different device, re-applies the selected one once. Bluetooth devices
    /// can report a device-ID write as successful before the transport has
    /// actually finished handing off audio, and the underlying player can
    /// also advance between pre-enqueued tracks (see `compatibleRun`)
    /// without going through `load()` again, so routing needs to be
    /// reasserted at those points rather than assumed to hold.
    /// Re-checks that audio is going where macOS is sending it, repairing if not.
    ///
    /// "Where macOS is sending it" is re-read live rather than taken from the device chosen
    /// when the track loaded. Previously this forced the cached device back on every track
    /// change, which actively fought a system output change and left Aro playing into the
    /// old device indefinitely while the Sound menu said otherwise.
    private func verifyAndRepairOutputRouting() {
        guard let player else { return }
        let device = deviceManager.defaultDevice ?? selectedDevice
        guard let device else { return }
        if selectedDevice?.uid != device.uid {
            selectedDevice = device
        }
        do {
            try verifyOutputRouting(player: player, requestedDevice: device)
        } catch {
            try? player.setOutputDeviceID(device.id)
            try? verifyOutputRouting(player: player, requestedDevice: device)
        }
    }

    /// Re-routes to a newly-selected system output device without interrupting playback
    /// where possible.
    ///
    /// Hog mode is released on the device being left before anything is acquired on the new
    /// one: holding exclusive access to a device Aro is no longer using would silence every
    /// other app on it for no reason.
    func systemDefaultDeviceChanged(to device: AudioOutputDevice?) {
        guard let device else { return }
        guard selectedDevice?.uid != device.uid else { return }
        if let previous = selectedDevice, previous.uid != device.uid {
            deviceManager.releaseHogMode(for: previous)
        }
        selectedDevice = device
        outputStatus.deviceName = device.name
        // A different device may not support the configured rate, and may need hog mode
        // acquiring, so the caller restarts the current track through the normal load path
        // rather than trying to mutate a running graph.
        configuredSampleRate = nil
        verifyAndRepairOutputRouting()
    }

    private func scheduleWirelessRoutingRecheck(playbackID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.activePlaybackID == playbackID else {
                return
            }
            self.verifyAndRepairOutputRouting()
        }
    }

    private func handleNowPlaying(_ url: URL) {
        guard let playbackID = activePlaybackID,
              let index = indicesByURL[url],
              songs.indices.contains(index) else {
            return
        }

        verifyAndRepairOutputRouting()
        if let selectedDevice, selectedDevice.transport.isWireless {
            scheduleWirelessRoutingRecheck(playbackID: playbackID)
        }

        let song = songs[index]
        currentSong = song
        streamingCoordinator?.playbackStarted(playbackItems, at: index)
        applyGain(for: song)
        outputStatus.sourceCodec = song.audioProperties?.codec
        outputStatus.sourceSampleRate = song.audioProperties?.sampleRate
        outputStatus.sourceBitDepth = song.audioProperties?.bitDepth
        outputStatus.sourceChannelCount = song.audioProperties?.channelCount
        if effectiveMode == .bitPerfect {
            outputStatus.sampleRate = song.audioProperties?.sampleRate
            outputStatus.bitDepth = song.audioProperties?.bitDepth
        }
        eventHandler?(.started(playbackID, song.url, song.duration ?? 0))
    }
}

extension HighResolutionPlaybackEngine: SFBAudioEngine.AudioPlayer.Delegate {
    /// The player's source node begins at 44.1 kHz stereo, then changes to the
    /// decoder's actual PCM format. Reconnect the downstream side of the EQ to
    /// the same concrete format before SFBAudioEngine reconnects its source
    /// node. Leaving the old implicit format in place causes
    /// `kAudioUnitErr_InvalidPropertyValue` when AVAudioEngine allocates the
    /// graph for tracks with a different sample rate or channel layout.
    nonisolated func audioPlayer(
        _ audioPlayer: SFBAudioEngine.AudioPlayer,
        reconfigureProcessingGraph engine: AVAudioEngine,
        with format: AVAudioFormat
    ) -> AVAudioNode {
        normalizationGraphState.reconfigure(
            engine: engine,
            format: format
        )
    }

    nonisolated func audioPlayer(
        _ audioPlayer: SFBAudioEngine.AudioPlayer,
        nowPlayingChanged nowPlaying: (any SFBAudioEngine.PCMDecoding)?
    ) {
        guard let url = nowPlaying?.inputSource.url else {
            return
        }
        Task { @MainActor [weak self] in
            self?.handleNowPlaying(url)
        }
    }

    nonisolated func audioPlayerEndOfAudio(
        _ audioPlayer: SFBAudioEngine.AudioPlayer
    ) {
        Task { @MainActor [weak self] in
            guard let self, let playbackID = self.activePlaybackID else {
                return
            }
            self.eventHandler?(.finished(playbackID))
        }
    }

    nonisolated func audioPlayer(
        _ audioPlayer: SFBAudioEngine.AudioPlayer,
        encounteredError error: any Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let playbackID = self.activePlaybackID,
               let url = self.currentSong?.url,
               self.resourcesByURL[url] != nil {
                Self.logger.error(
                    "Progressive decoder failed during playback: \(error.localizedDescription, privacy: .public)"
                )
                self.eventHandler?(
                    .progressiveStreamingFailed(
                        playbackID,
                        error.localizedDescription
                    )
                )
            } else {
                self.eventHandler?(.failed(error.localizedDescription))
            }
        }
    }
}
