import Foundation
import AroCommon

struct FolderScanOutcome: Sendable {
    let songs: [Song]
    let skippedFileCount: Int
}

struct ScanWatchedFolder: Sendable {
    private let scanner: any AudioScanning
    private let catalog: any LibraryCatalogRepository

    init(
        scanner: any AudioScanning,
        catalog: any LibraryCatalogRepository
    ) {
        self.scanner = scanner
        self.catalog = catalog
    }

    func execute(folderID: UUID, url: URL) async -> FolderScanOutcome {
        let result = await scanner.scan(folder: url)
        return FolderScanOutcome(
            songs: catalog.reconcile(
                songs: result.songs,
                folderID: folderID
            ),
            skippedFileCount: result.skippedFileCount
        )
    }
}
