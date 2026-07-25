import Foundation

@main
struct LibraryApplicationChecks {
    static func main() async {
        let song = Song(
            url: URL(fileURLWithPath: "/music/song.flac"),
            title: "Song",
            artist: "Artist",
            duration: 10
        )
        let outcome = await ScanWatchedFolder(
            scanner: StandaloneScanner(song: song),
            catalog: StandaloneCatalog()
        ).execute(
            folderID: UUID(),
            url: URL(fileURLWithPath: "/music")
        )

        precondition(outcome.songs == [song])
        precondition(outcome.skippedFileCount == 2)
        print("Library application checks passed")
    }
}

private struct StandaloneScanner: AudioScanning {
    let song: Song

    func scan(folder: URL) async -> ScanResult {
        ScanResult(songs: [song], skippedFileCount: 2)
    }
}

private struct StandaloneCatalog: LibraryCatalogRepository {
    func watchedFolders() -> [StoredWatchedFolder] { [] }
    func save(folder: WatchedFolder) {}
    func removeFolder(id: UUID) {}
    func markFolderUnavailable(id: UUID) {}
    func songs(folderID: UUID) -> [Song] { [] }

    func reconcile(songs: [Song], folderID: UUID) -> [Song] {
        songs
    }
}
