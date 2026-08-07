import Observation
import AroCommon

@MainActor
@Observable
final class PlaybackPreferences {
    var mode: PlaybackMode {
        didSet { persist() }
    }

    var outputDeviceUID: String? {
        didSet { persist() }
    }

    var hogModeEnabled: Bool {
        didSet { persist() }
    }

    var targetLUFS: Double {
        didSet { persist() }
    }

    /// Remembered across launches. Playback volume used to reset to full scale on every
    /// launch, which is a nasty surprise on a system whose amplifier is already turned up.
    var volume: Double {
        didSet { persist() }
    }

    var shuffleEnabled: Bool {
        didSet { persist() }
    }

    var repeatMode: PlaybackRepeatMode {
        didSet { persist() }
    }

    @ObservationIgnored private let store: any PlaybackPreferenceStoring

    init(
        store: any PlaybackPreferenceStoring =
            InMemoryPlaybackPreferenceStore()
    ) {
        self.store = store
        let values = store.load()
        mode = values.mode
        outputDeviceUID = values.outputDeviceUID
        hogModeEnabled = values.hogModeEnabled
        targetLUFS = values.targetLUFS
        shuffleEnabled = values.shuffleEnabled
        volume = values.volume
        repeatMode = values.repeatMode
    }

    private func persist() {
        store.save(
            PlaybackPreferenceValues(
                mode: mode,
                outputDeviceUID: outputDeviceUID,
                hogModeEnabled: hogModeEnabled,
                targetLUFS: targetLUFS,
                shuffleEnabled: shuffleEnabled,
                volume: volume,
                repeatMode: repeatMode
            )
        )
    }
}
