import Foundation
import SonoraCommon

struct ManageWatchedFolders: Sendable {
    private let catalog: any LibraryCatalogRepository

    init(catalog: any LibraryCatalogRepository) {
        self.catalog = catalog
    }

    func storedFolders() -> [StoredWatchedFolder] {
        catalog.watchedFolders()
    }

    func storedSongs(folderID: UUID) -> [Song] {
        catalog.songs(folderID: folderID)
    }

    func save(_ folder: WatchedFolder) {
        catalog.save(folder: folder)
    }

    func remove(folderID: UUID) {
        catalog.removeFolder(id: folderID)
    }

    func markUnavailable(folderID: UUID) {
        catalog.markFolderUnavailable(id: folderID)
    }
}
