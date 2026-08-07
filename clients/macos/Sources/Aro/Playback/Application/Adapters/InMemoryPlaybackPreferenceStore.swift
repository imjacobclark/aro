import Foundation
import AroCommon

final class InMemoryPlaybackPreferenceStore:
    PlaybackPreferenceStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: PlaybackPreferenceValues

    init(values: PlaybackPreferenceValues = PlaybackPreferenceValues()) {
        self.values = values
    }

    func load() -> PlaybackPreferenceValues {
        lock.withLock { values }
    }

    func save(_ values: PlaybackPreferenceValues) {
        lock.withLock {
            self.values = values
        }
    }
}
