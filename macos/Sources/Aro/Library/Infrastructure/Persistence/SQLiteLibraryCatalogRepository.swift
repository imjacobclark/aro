import Foundation
import AroCommon

struct SQLiteLibraryCatalogRepository: LibraryCatalogRepository {
    private let database: LibraryDatabase
    private let loudness: any LoudnessAnalysisRepository

    init(
        database: LibraryDatabase,
        loudness: any LoudnessAnalysisRepository
    ) {
        self.database = database
        self.loudness = loudness
    }

    func watchedFolders() -> [StoredWatchedFolder] {
        database.watchedFolders().map {
            StoredWatchedFolder(
                id: $0.id,
                displayName: $0.displayName,
                path: $0.path,
                bookmarkData: $0.bookmarkData
            )
        }
    }

    func save(folder: WatchedFolder) {
        database.save(folder: folder)
    }

    func removeFolder(id: UUID) {
        database.removeFolder(id: id)
    }

    func markFolderUnavailable(id: UUID) {
        database.markFolderUnavailable(id: id)
    }

    func songs(folderID: UUID) -> [Song] {
        enriching(database.songs(folderID: folderID))
    }

    func reconcile(songs: [Song], folderID: UUID) -> [Song] {
        enriching(
            database.reconcile(songs: songs, folderID: folderID)
        )
    }

    private func enriching(_ songs: [Song]) -> [Song] {
        songs.map { song in
            guard song.loudness == nil,
                  let fingerprint = song.fileFingerprint?.cacheKey,
                  let analysis = loudness.analysis(
                      fingerprint: fingerprint,
                      algorithmVersion: LoudnessAnalysis.algorithmVersion
                  ) else {
                return song
            }
            var enriched = song
            enriched.loudness = analysis
            return enriched
        }
    }
}
