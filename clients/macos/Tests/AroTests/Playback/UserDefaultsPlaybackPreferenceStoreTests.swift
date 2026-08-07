#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

final class UserDefaultsPlaybackPreferenceStoreTests: XCTestCase {
    func testSaveClampsTargetLUFSToSupportedRange() {
        let suiteName = "UserDefaultsPlaybackPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPlaybackPreferenceStore(defaults: defaults)

        store.save(PlaybackPreferenceValues(targetLUFS: -2))
        XCTAssertEqual(store.load().targetLUFS, -8)

        store.save(PlaybackPreferenceValues(targetLUFS: -40))
        XCTAssertEqual(store.load().targetLUFS, -24)

        store.save(PlaybackPreferenceValues(targetLUFS: -16))
        XCTAssertEqual(store.load().targetLUFS, -16)
    }

    func testShuffleAndRepeatPreferencesRoundTrip() {
        let suiteName =
            "UserDefaultsPlaybackPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPlaybackPreferenceStore(defaults: defaults)

        store.save(
            PlaybackPreferenceValues(
                shuffleEnabled: true,
                repeatMode: .one
            )
        )

        XCTAssertTrue(store.load().shuffleEnabled)
        XCTAssertEqual(store.load().repeatMode, .one)
    }
}
#endif
