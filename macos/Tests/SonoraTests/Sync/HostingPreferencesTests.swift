#if canImport(Testing)
import Foundation
import Testing
@testable import Sonora

@MainActor
@Suite("Hosting preferences")
struct HostingPreferencesTests {
    @Test("Protected user folders are rejected for background hosting")
    func testProtectedUserFoldersAreRejectedForBackgroundHosting() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        for directory in ["Desktop", "Documents", "Downloads"] {
            let location = home
                .appendingPathComponent(directory)
                .appendingPathComponent("Sonora Hub")
                .path
            let isSupported = SyncPreferences.isSupportedHelperLocation(
                location
            )
            #expect(!isSupported)
        }
    }

    @Test("The recommended hub data location is background-accessible")
    func testRecommendedLocationIsAvailableToBackgroundHelper() {
        let isSupported = SyncPreferences.isSupportedHelperLocation(
            SyncPreferences.recommendedDataLocation
        )
        #expect(isSupported)
    }
}
#endif
