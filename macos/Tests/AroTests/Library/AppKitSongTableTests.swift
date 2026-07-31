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
        let scrollView = coordinator.makeScrollView()
        return scrollView.documentView as! NSTableView
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
