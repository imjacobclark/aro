import AVFAudio
import AroCommon
import Foundation
import SFBAudioEngine

@MainActor
final class HighResolutionPlaybackEngine: NSObject, AudioPlaybackEngine {
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

    private(set) var outputStatus = PlaybackOutputStatus()

    private var player: SFBAudioEngine.AudioPlayer?
    private var normalizationNode: AVAudioUnitEQ?
    private let preferences: PlaybackPreferences
    private let deviceManager: any AudioDeviceManaging
    private var songs: [Song] = []
    private var indicesByURL: [URL: Int] = [:]
    private var currentSong: Song?
    private var activePlaybackID: UUID?
    private var selectedDevice: AudioOutputDevice?
    private var requestedVolume: Float = 1
    private var normalizationGraphIsActive = false
    private var effectiveMode: PlaybackMode = .bitPerfect
    private var meterTapIsInstalled = false
    private var meterRelay: AudioMeterRelay?

    init(
        preferences: PlaybackPreferences,
        deviceManager: any AudioDeviceManaging
    ) {
        self.preferences = preferences
        self.deviceManager = deviceManager
        super.init()
    }

    func load(
        songs: [Song],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval {
        guard songs.indices.contains(index) else {
            throw PlaybackEngineError.invalidAudioFile
        }

        stop()
        do {
        self.songs = songs
        activePlaybackID = playbackID

        let firstSong = songs[index]
        guard let properties = firstSong.audioProperties,
              let sampleRate = properties.sampleRate,
              sampleRate > 0 else {
            throw PlaybackEngineError.missingAudioProperties
        }

        let device = deviceManager.selectedDevice(
            for: preferences.outputDeviceUID
        )
        effectiveMode = PlaybackRoutePolicy().effectiveMode(
            preferredMode: preferences.mode,
            device: device
        )
        var outputSampleRate = sampleRate
        if let device {
            if device.transport.isWireless {
                outputSampleRate = deviceManager.nominalSampleRate(for: device) ?? sampleRate
            } else if effectiveMode == .normalized,
               !device.supports(sampleRate: sampleRate) {
                outputSampleRate = deviceManager.nominalSampleRate(for: device)
                    .flatMap { device.supports(sampleRate: $0) ? $0 : nil }
                    ?? device.nearestSupportedSampleRate(to: sampleRate)
                    ?? sampleRate
            }

            let acquiredHog = try deviceManager.configure(
                device: device,
                sampleRate: outputSampleRate,
                acquireHogMode: preferences.hogModeEnabled && !device.transport.isWireless
            )
            selectedDevice = device
            outputStatus.isExclusive = acquiredHog
        }

        // Hardware sample-rate changes post an asynchronous AVAudioEngine
        // configuration notification. Constructing the player only after the
        // device has been configured prevents SFBAudioEngine from observing
        // Core Audio's transient 0 Hz/0-channel intermediate format.
        let player = SFBAudioEngine.AudioPlayer()
        player.delegate = self
        self.player = player
        normalizationNode = AVAudioUnitEQ(numberOfBands: 0)
        if let device, player.outputDeviceID != device.id {
            try player.setOutputDeviceID(device.id)
        }
        if let device {
            try verifyOutputRouting(player: player, requestedDevice: device)
        }

        outputStatus.mode = effectiveMode
        outputStatus.transport = device?.transport ?? .other
        outputStatus.sourceCodec = properties.codec
        outputStatus.sourceSampleRate = sampleRate
        outputStatus.sourceBitDepth = properties.bitDepth
        outputStatus.sourceChannelCount = properties.channelCount
        outputStatus.sampleRate = outputSampleRate
        outputStatus.bitDepth = properties.bitDepth
        outputStatus.warning = deviceManager.lastWarning
        configureProcessingGraph(for: effectiveMode)
        installMeterTap()

        let compatibleSongs = compatibleRun(in: songs, startingAt: index)
        guard let first = compatibleSongs.first else {
            throw PlaybackEngineError.invalidAudioFile
        }

        self.songs = songs
        indicesByURL = Dictionary(
            uniqueKeysWithValues: compatibleSongs.map { ($0.element.url, $0.offset) }
        )
        currentSong = first.element
        applyGain(for: first.element)

        try player.enqueue(first.element.url, immediate: true)
        for queued in compatibleSongs.dropFirst() {
            try player.enqueue(queued.element.url)
        }

        if time > 0 {
            _ = player.seek(time: time)
        }

        return first.element.duration ?? 0
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
        activePlaybackID = nil
        discardPlayer()
        deviceManager.releaseHogMode(for: selectedDevice)
        selectedDevice = nil
        songs = []
        indicesByURL = [:]
        currentSong = nil
        levelHandler?(Self.silentMeterLevels)
    }

    private func compatibleRun(
        in songs: [Song],
        startingAt index: Int
    ) -> [(offset: Int, element: Song)] {
        let first = songs[index]
        let sampleRate = first.audioProperties?.sampleRate
        let channelCount = first.audioProperties?.channelCount
        var result: [(offset: Int, element: Song)] = []

        for candidateIndex in index..<songs.count {
            let song = songs[candidateIndex]
            guard song.audioProperties?.sampleRate == sampleRate,
                  song.audioProperties?.channelCount == channelCount else {
                break
            }
            if effectiveMode == .normalized, song.loudness == nil {
                break
            }
            result.append((candidateIndex, song))
        }
        return result
    }

    private func applyGain(for song: Song?) {
        let gainDecibels: Double
        if effectiveMode == .normalized {
            guard let loudness = song?.loudness else {
                outputStatus.warning = PlaybackEngineError
                    .missingLoudnessAnalysis.localizedDescription
                return
            }
            gainDecibels = loudness.safeGainDecibels(
                targetLUFS: preferences.targetLUFS
            )
        } else {
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
        if let player {
            do {
                try player.setVolume(1)
                let actualVolume = player.volume
                if actualVolume.isFinite, actualVolume < 0.999 {
                    outputStatus.warning =
                        "Core Audio reports the output below unity gain (\(Int(actualVolume * 100))%). Check the device level in Audio MIDI Setup."
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
                engine.connect(
                    player.sourceNode,
                    to: normalizationNode,
                    format: nil
                )
                engine.connect(
                    normalizationNode,
                    to: player.mainMixerNode,
                    format: nil
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

    private func handleNowPlaying(_ url: URL) {
        guard let playbackID = activePlaybackID,
              let index = indicesByURL[url],
              songs.indices.contains(index) else {
            return
        }

        let song = songs[index]
        currentSong = song
        applyGain(for: song)
        outputStatus.sourceCodec = song.audioProperties?.codec
        outputStatus.sourceSampleRate = song.audioProperties?.sampleRate
        outputStatus.sourceBitDepth = song.audioProperties?.bitDepth
        outputStatus.sourceChannelCount = song.audioProperties?.channelCount
        if effectiveMode == .bitPerfect {
            outputStatus.sampleRate = song.audioProperties?.sampleRate
            outputStatus.bitDepth = song.audioProperties?.bitDepth
        }
        eventHandler?(.started(playbackID, url, song.duration ?? 0))
    }
}

extension HighResolutionPlaybackEngine: SFBAudioEngine.AudioPlayer.Delegate {
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
            self?.eventHandler?(.failed(error.localizedDescription))
        }
    }
}
