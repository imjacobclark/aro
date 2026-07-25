import Foundation
import SonoraCommon

protocol LibraryCatalogRepository: Sendable {
    func watchedFolders() -> [StoredWatchedFolder]
    func save(folder: WatchedFolder)
    func removeFolder(id: UUID)
    func markFolderUnavailable(id: UUID)
    func songs(folderID: UUID) -> [Song]
    func reconcile(songs: [Song], folderID: UUID) -> [Song]
}
