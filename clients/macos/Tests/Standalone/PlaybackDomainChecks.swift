import Foundation

@main
@MainActor
struct PlaybackDomainChecks {
    static func main() {
        verifyQueuePolicy()
        verifyVisualizerResponse()
        verifyListeningSessions()
        print("Playback domain checks passed")
    }

    private static func verifyQueuePolicy() {
        let first = song(title: "First")
        let second = song(title: "Second")
        let prepared = PlaybackQueuePolicy().prepare(
            selectedSong: second,
            requestedQueue: [first, second, second]
        )
        precondition(prepared.songs == [first, second])
        precondition(prepared.selectedIndex == 1)

        let reconciled = PlaybackQueuePolicy().reconcile(
            queue: prepared.songs,
            currentSong: second,
            availableSongs: [second]
        )
        precondition(reconciled.songs == [second])
        precondition(reconciled.currentIndex == 0)
    }

    private static func verifyVisualizerResponse() {
        let smoother = VisualizerLevelSmoother()
        let attack = smoother.update(
            current: [0],
            incoming: [1]
        )
        let release = smoother.update(
            current: [1],
            incoming: [0.5]
        )
        precondition(attack == [0.62])
        precondition(release == [0.91])
        precondition(
            smoother.update(current: [0.5], incoming: [0]) == [0]
        )
    }

    private static func verifyListeningSessions() {
        let history = RecordingHistory()
        let tracker = ListeningSessionTracker(history: history)
        let trackID = UUID()
        let start = Date(timeIntervalSince1970: 100)

        tracker.begin(trackID: trackID, now: start)
        tracker.heartbeatIfNeeded(at: start.addingTimeInterval(4))
        precondition(history.heartbeatCount == 0)
        tracker.heartbeatIfNeeded(at: start.addingTimeInterval(5))
        precondition(history.heartbeatCount == 1)
        tracker.end(completed: true)
        precondition(history.completed)
    }

    private static func song(title: String) -> Song {
        Song(
            libraryID: UUID(),
            url: URL(fileURLWithPath: "/Music/\(title).flac"),
            title: title,
            artist: "Artist",
            duration: nil
        )
    }
}

private final class RecordingHistory:
    @unchecked Sendable,
    ListeningHistoryRecording
{
    private let lock = NSLock()
    private var storedHeartbeatCount = 0
    private var storedCompleted = false

    var heartbeatCount: Int {
        lock.withLock { storedHeartbeatCount }
    }

    var completed: Bool {
        lock.withLock { storedCompleted }
    }

    func beginSession(trackID: UUID) -> UUID {
        UUID()
    }

    func heartbeat(sessionID: UUID) {
        lock.withLock {
            storedHeartbeatCount += 1
        }
    }

    func endSession(sessionID: UUID, completed: Bool) {
        lock.withLock {
            storedCompleted = completed
        }
    }
}
