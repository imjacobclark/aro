#if canImport(XCTest)
import Foundation
import XCTest
@testable import AroCommon

final class PlaybackApplicationTests: XCTestCase {
    func testWirelessRoutesUseSharedNormalizedPlayback() {
        let device = AudioOutputDevice(
            id: 1,
            uid: "bluetooth",
            name: "Headphones",
            sampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 48_000)],
            transport: .bluetooth
        )
        let policy = PlaybackRoutePolicy()

        XCTAssertEqual(policy.effectiveMode(preferredMode: .bitPerfect, device: device), .normalized)
        XCTAssertFalse(policy.allowsExclusiveAccess(for: device))
        XCTAssertNotNil(policy.warning(for: device))
    }

    func testWiredRoutesPreserveBitPerfectPreference() {
        let device = AudioOutputDevice(
            id: 2,
            uid: "usb",
            name: "DAC",
            sampleRateRanges: [],
            transport: .usb
        )
        XCTAssertEqual(PlaybackRoutePolicy().effectiveMode(preferredMode: .bitPerfect, device: device), .bitPerfect)
    }

    func testLoudnessGateErrorOnlyAppliesToNormalizedModeWithMissingAnalysis() {
        let policy = PlaybackRoutePolicy()
        let loudness = LoudnessAnalysis(integratedLUFS: -14, peakAmplitude: 0.9)

        XCTAssertEqual(
            policy.loudnessGateError(effectiveMode: .normalized, leadSongLoudness: nil),
            .missingLoudnessAnalysis
        )
        XCTAssertNil(
            policy.loudnessGateError(effectiveMode: .normalized, leadSongLoudness: loudness)
        )
        XCTAssertNil(
            policy.loudnessGateError(effectiveMode: .bitPerfect, leadSongLoudness: nil)
        )
    }

    func testQueuePreparationDeduplicatesSongsAndKeepsSelection() {
        let selected = makeSong(id: "selected", title: "Selected")
        let duplicate = makeSong(id: "duplicate", title: "Duplicate")
        let policy = PlaybackQueuePolicy()

        let result = policy.prepare(
            selectedSong: selected,
            requestedQueue: [selected, duplicate, duplicate]
        )

        XCTAssertEqual(result.selectedIndex, 0)
        XCTAssertEqual(result.songs.map(\.title), ["Selected", "Duplicate"])
    }

    func testQueueReconciliationDropsUnavailableSongsAndUpdatesCurrentIndex() {
        let current = makeSong(id: "current", title: "Current")
        let missing = makeSong(id: "missing", title: "Missing")
        let policy = PlaybackQueuePolicy()

        let result = policy.reconcile(
            queue: [missing, current],
            currentSong: current,
            availableSongs: [current]
        )

        XCTAssertEqual(result.songs.map(\.title), ["Current"])
        XCTAssertEqual(result.currentSong?.title, "Current")
        XCTAssertEqual(result.currentIndex, 0)
    }

    private func makeSong(id: String, title: String) -> Song {
        let libraryID: UUID
        switch id {
        case "selected":
            libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case "duplicate":
            libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case "current":
            libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        default:
            libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        }

        return Song(
            libraryID: libraryID,
            url: URL(fileURLWithPath: "/Music/\(id).mp3"),
            title: title,
            artist: "Artist",
            duration: 60
        )
    }
}
#endif
