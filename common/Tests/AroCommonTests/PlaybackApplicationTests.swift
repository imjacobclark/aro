#if canImport(XCTest)
import Foundation
import XCTest
@testable import AroCommon

final class PlaybackApplicationTests: XCTestCase {
    @MainActor
    func testListeningTrackerUsesOneLifecycleForHistoryAndLiveActivity() {
        let history = RecordingHistory()
        let activity = RecordingActivity()
        let tracker = ListeningSessionTracker(
            history: history,
            activity: activity
        )
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.begin(
            trackID: UUID(),
            contentHash: String(repeating: "a", count: 64),
            outputStatus: PlaybackOutputStatus(deviceName: "DAC"),
            now: start
        )
        tracker.heartbeatIfNeeded(
            position: 6,
            duration: 120,
            bufferedFraction: 0.5,
            buffering: true,
            outputStatus: PlaybackOutputStatus(deviceName: "DAC"),
            at: start.addingTimeInterval(6)
        )
        tracker.end(completed: true)

        XCTAssertEqual(history.begins, 1)
        XCTAssertEqual(history.heartbeats, 1)
        XCTAssertEqual(history.ends, 1)
        XCTAssertEqual(activity.snapshots.map(\.revision), [1, 2, 3])
        XCTAssertEqual(
            activity.snapshots.map(\.state),
            [.playing, .buffering, .stopped]
        )
        XCTAssertTrue(activity.snapshots.last?.completed == true)
    }

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

private final class RecordingHistory:
    ListeningHistoryRecording,
    @unchecked Sendable
{
    var begins = 0
    var heartbeats = 0
    var ends = 0

    func beginSession(trackID: UUID) -> UUID {
        begins += 1
        return UUID()
    }

    func heartbeat(sessionID: UUID) {
        heartbeats += 1
    }

    func endSession(sessionID: UUID, completed: Bool) {
        ends += 1
    }
}

private final class RecordingActivity:
    PlaybackActivityReporting,
    @unchecked Sendable
{
    var snapshots: [PlaybackActivitySnapshot] = []

    func report(_ snapshot: PlaybackActivitySnapshot) {
        snapshots.append(snapshot)
    }
}
#endif
