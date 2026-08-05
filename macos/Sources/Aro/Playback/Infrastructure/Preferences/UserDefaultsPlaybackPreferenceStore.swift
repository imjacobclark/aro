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
        static let volume = "playback.volume"
        static let shuffleEnabled = "playback.shuffleEnabled"
        static let repeatMode = "playback.repeatMode"
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
                ),
            shuffleEnabled: defaults.bool(forKey: Key.shuffleEnabled),
            volume: defaults.object(forKey: Key.volume) == nil
                ? 1
                : min(max(defaults.double(forKey: Key.volume), 0), 1),
            repeatMode: defaults.string(forKey: Key.repeatMode)
                .flatMap(PlaybackRepeatMode.init(rawValue:))
                ?? .off
        )
    }

    func save(_ values: PlaybackPreferenceValues) {
        defaults.set(values.mode.rawValue, forKey: Key.mode)
        defaults.set(values.outputDeviceUID, forKey: Key.outputDeviceUID)
        defaults.set(values.hogModeEnabled, forKey: Key.hogMode)
        defaults.set(
            min(max(values.targetLUFS, -24), -8),
            forKey: Key.targetLUFS
        )
        defaults.set(values.shuffleEnabled, forKey: Key.shuffleEnabled)
        defaults.set(min(max(values.volume, 0), 1), forKey: Key.volume)
        defaults.set(values.repeatMode.rawValue, forKey: Key.repeatMode)
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
