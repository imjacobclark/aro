#if canImport(Testing)
import Foundation
import Testing
@testable import Sonora

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
            #expect(!SyncPreferences.isSupportedHelperLocation(location))
        }
    }

    @Test("The recommended hub data location is background-accessible")
    func testRecommendedLocationIsAvailableToBackgroundHelper() {
        #expect(
            SyncPreferences.isSupportedHelperLocation(
                SyncPreferences.recommendedDataLocation
            )
        )
    }
}
#endif
