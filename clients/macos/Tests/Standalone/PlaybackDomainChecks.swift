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

    /// Heartbeats are rate-limited to one every five seconds, so a hub is not asked to
    /// record a snapshot on every tick of the progress timer.
    private static func verifyListeningSessions() {
        let activity = RecordingActivity()
        let tracker = ListeningSessionTracker(activity: activity)
        let trackID = UUID()
        let start = Date(timeIntervalSince1970: 100)

        tracker.begin(trackID: trackID, now: start)
        precondition(activity.snapshots.count == 1)
        tracker.heartbeatIfNeeded(at: start.addingTimeInterval(4))
        precondition(activity.snapshots.count == 1)
        tracker.heartbeatIfNeeded(at: start.addingTimeInterval(5))
        precondition(activity.snapshots.count == 2)
        tracker.end(completed: true)
        precondition(activity.snapshots.last?.completed == true)
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

private final class RecordingActivity:
    @unchecked Sendable,
    PlaybackActivityReporting
{
    private let lock = NSLock()
    private var stored: [PlaybackActivitySnapshot] = []

    var snapshots: [PlaybackActivitySnapshot] {
        lock.withLock { stored }
    }

    func report(_ snapshot: PlaybackActivitySnapshot) {
        lock.withLock { stored.append(snapshot) }
    }
}
