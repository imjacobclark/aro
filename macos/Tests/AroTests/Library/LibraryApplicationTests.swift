#if canImport(Testing)
import Foundation
import AroCommon
import Testing
@testable import Aro

@Suite("Library application")
struct LibraryApplicationTests {
    @Test("Scanning delegates discovery and reconciliation through ports")
    func scansAndReconciles() async {
        let folderID = UUID()
        let song = Song(
            url: URL(fileURLWithPath: "/music/song.flac"),
            title: "Song",
            artist: "Artist",
            duration: 10
        )
        let outcome = await ScanWatchedFolder(
            scanner: StubScanner(song: song),
            catalog: StubCatalog()
        ).execute(
            folderID: folderID,
            url: URL(fileURLWithPath: "/music")
        )

        #expect(outcome.songs.count == 1)
        #expect(outcome.songs[0].title == "Song")
        #expect(outcome.skippedFileCount == 2)
    }
}

private struct StubScanner: AudioScanning {
    let song: Song

    func scan(folder: URL) async -> ScanResult {
        ScanResult(songs: [song], skippedFileCount: 2)
    }
}

private struct StubCatalog: LibraryCatalogRepository {
    func watchedFolders() -> [StoredWatchedFolder] { [] }
    func save(folder: WatchedFolder) {}
    func removeFolder(id: UUID) {}
    func markFolderUnavailable(id: UUID) {}
    func songs(folderID: UUID) -> [Song] { [] }

    func reconcile(songs: [Song], folderID: UUID) -> [Song] {
        songs
    }
}
#endif
