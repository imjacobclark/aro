#if canImport(Testing)
import AppKit
import AroCommon
import Foundation
import Testing
@testable import Aro

@MainActor
@Suite("AppKit song table")
struct AppKitSongTableTests {
    @Test("Playback and cache cell updates preserve user selection")
    func displayUpdatesPreserveSelection() {
        let first = makeSong(title: "First")
        let second = makeSong(title: "Second")
        let coordinator = makeCoordinator(
            songs: [first, second],
            currentSongID: first.id
        )
        let tableView = makeTableView(coordinator)
        tableView.selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        coordinator.update(
            songs: [first, second],
            currentSongID: second.id,
            downloadedSongIDs: [second.id],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in }
        )

        #expect(tableView.selectedRow == 1)

        let renamedSecond = makeSong(
            id: second.libraryID,
            title: "Second (Updated)"
        )
        coordinator.update(
            songs: [first, renamedSecond],
            currentSongID: second.id,
            downloadedSongIDs: [second.id],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in }
        )

        #expect(tableView.selectedRow == 1)
    }

    @Test("Library changes preserve selection by song identity")
    func libraryChangesPreserveSelectionByID() {
        let first = makeSong(title: "First")
        let second = makeSong(title: "Second")
        let coordinator = makeCoordinator(songs: [first, second])
        let tableView = makeTableView(coordinator)
        tableView.selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        coordinator.update(
            songs: [second, first],
            currentSongID: nil,
            downloadedSongIDs: [],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in }
        )

        #expect(tableView.selectedRow == 0)

        coordinator.update(
            songs: [first],
            currentSongID: nil,
            downloadedSongIDs: [],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in }
        )

        #expect(tableView.selectedRow == -1)
    }

    @Test("Primary action plays and selects the activated row")
    func primaryActionUsesActivatedRow() {
        let first = makeSong(title: "First")
        let second = makeSong(title: "Second")
        var playedSongID: Song.ID?
        let coordinator = AppKitSongTable.Coordinator(
            songs: [first, second],
            currentSongID: first.id,
            downloadedSongIDs: [],
            presentation: .library,
            onPlay: { song in
                playedSongID = song.id
            },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in }
        )
        let tableView = makeTableView(coordinator)
        tableView.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )

        coordinator.activate(row: 1)

        #expect(playedSongID == second.id)
        #expect(tableView.selectedRow == 1)
    }

    @Test("Opening a collection centres the table on the playing song")
    func focusesPlayingSongOncePerCollection() async {
        let songs = (0 ..< 60).map { makeSong(title: "Song \($0)") }
        let coordinator = makeCoordinator(songs: [])
        let scrollView = makeScrollView(coordinator)
        let tableView = scrollView.documentView as! NSTableView

        coordinator.update(
            songs: songs,
            currentSongID: songs[50].id,
            downloadedSongIDs: [],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in },
            focusToken: "Songs"
        )
        await settle()

        let playingRow = tableView.rect(ofRow: 50)
        #expect(scrollView.contentView.bounds.intersects(playingRow))

        // Scrolling away and receiving another update for the same collection
        // must leave the reader where they were.
        scrollView.contentView.scroll(to: .zero)
        coordinator.update(
            songs: songs,
            currentSongID: songs[50].id,
            downloadedSongIDs: [songs[50].id],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in },
            focusToken: "Songs"
        )
        await settle()

        #expect(scrollView.contentView.bounds.origin.y == 0)

        // A different collection is a fresh navigation, so it focuses again.
        coordinator.update(
            songs: songs,
            currentSongID: songs[50].id,
            downloadedSongIDs: [],
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in },
            focusToken: "Jazz"
        )
        await settle()

        #expect(scrollView.contentView.bounds.intersects(playingRow))
    }

    /// The table defers its scroll to the next main queue turn, once layout has
    /// sized it; this gives that turn a chance to run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func makeCoordinator(
        songs: [Song],
        currentSongID: Song.ID? = nil
    ) -> AppKitSongTable.Coordinator {
        AppKitSongTable.Coordinator(
            songs: songs,
            currentSongID: currentSongID,
            downloadedSongIDs: [],
            presentation: .library,
            onPlay: { _ in },
            onSyncTrackData: { _ in },
            onRequestRemoval: { _ in }
        )
    }

    private func makeTableView(
        _ coordinator: AppKitSongTable.Coordinator
    ) -> NSTableView {
        makeScrollView(coordinator).documentView as! NSTableView
    }

    /// Sized and laid out, so row geometry and the visible rectangle are real
    /// rather than zero.
    private func makeScrollView(
        _ coordinator: AppKitSongTable.Coordinator
    ) -> NSScrollView {
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func makeSong(
        id: UUID = UUID(),
        title: String
    ) -> Song {
        Song(
            libraryID: id,
            url: URL(fileURLWithPath: "/music/\(title).m4a"),
            title: title,
            artist: "Artist",
            duration: 180
        )
    }
}
#endif
