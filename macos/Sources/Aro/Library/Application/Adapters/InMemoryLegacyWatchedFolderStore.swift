import AroCommon

import Foundation

final class InMemoryLegacyWatchedFolderStore:
    LegacyWatchedFolderStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var folders: [StoredWatchedFolder]

    init(folders: [StoredWatchedFolder] = []) {
        self.folders = folders
    }

    func load() -> [StoredWatchedFolder] {
        lock.withLock { folders }
    }

    func save(_ folders: [StoredWatchedFolder]) {
        lock.withLock {
            self.folders = folders
        }
    }
}
