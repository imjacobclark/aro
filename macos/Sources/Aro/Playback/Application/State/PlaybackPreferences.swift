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
    }

    private func persist() {
        store.save(
            PlaybackPreferenceValues(
                mode: mode,
                outputDeviceUID: outputDeviceUID,
                hogModeEnabled: hogModeEnabled,
                targetLUFS: targetLUFS
            )
        )
    }
}
