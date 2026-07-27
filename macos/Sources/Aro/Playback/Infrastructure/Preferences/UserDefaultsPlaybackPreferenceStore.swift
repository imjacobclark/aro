import Foundation
import AroCommon

struct UserDefaultsPlaybackPreferenceStore:
    PlaybackPreferenceStoring,
    @unchecked Sendable
{
    private enum Key {
        static let mode = "playback.mode"
        static let outputDeviceUID = "playback.outputDeviceUID"
        static let hogMode = "playback.hogMode"
        static let targetLUFS = "playback.targetLUFS"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PlaybackPreferenceValues {
        PlaybackPreferenceValues(
            mode: defaults.string(forKey: Key.mode)
                .flatMap(PlaybackMode.init(rawValue:))
                ?? .bitPerfect,
            outputDeviceUID: defaults.string(
                forKey: Key.outputDeviceUID
            ),
            hogModeEnabled: defaults.bool(forKey: Key.hogMode),
            targetLUFS: defaults.object(forKey: Key.targetLUFS) == nil
                ? -14
                : min(
                    max(defaults.double(forKey: Key.targetLUFS), -24),
                    -8
                )
        )
    }

    func save(_ values: PlaybackPreferenceValues) {
        defaults.set(values.mode.rawValue, forKey: Key.mode)
        defaults.set(values.outputDeviceUID, forKey: Key.outputDeviceUID)
        defaults.set(values.hogModeEnabled, forKey: Key.hogMode)
        defaults.set(values.targetLUFS, forKey: Key.targetLUFS)
    }
}

extension PlaybackPreferences {
    convenience init(defaults: UserDefaults) {
        self.init(
            store: UserDefaultsPlaybackPreferenceStore(
                defaults: defaults
            )
        )
    }
}
