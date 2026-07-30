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

    @discardableResult
    func applyIdentification(
        contentHash: String,
        title: String?,
        artist: String?,
        album: String?,
        musicbrainzRecordingID: String?,
        acoustidID: String?,
        artworkData: Data?,
        musicbrainzGenresJSON: String?,
        moodTagsJSON: String?
    ) -> Bool {
        database.applyIdentification(
            contentHash: contentHash,
            title: title,
            artist: artist,
            album: album,
            musicbrainzRecordingID: musicbrainzRecordingID,
            acoustidID: acoustidID,
            artworkData: artworkData,
            musicbrainzGenresJSON: musicbrainzGenresJSON,
            moodTagsJSON: moodTagsJSON
        )
    }

    func pendingArtworkDownloads(limit: Int) -> [PendingArtwork] {
        database.pendingArtworkDownloads(limit: limit)
    }

    func storeArtwork(trackID: String, data: Data) {
        database.storeArtwork(trackID: trackID, data: data)
    }

    private func enriching(_ songs: [Song]) -> [Song] {
        let missingFingerprints = songs.compactMap { song in
            song.loudness == nil ? song.fileFingerprint?.cacheKey : nil
        }
        guard !missingFingerprints.isEmpty else { return songs }
        let analyses = loudness.analyses(
            fingerprints: missingFingerprints,
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        )
        guard !analyses.isEmpty else { return songs }
        return songs.map { song in
            guard song.loudness == nil,
                  let fingerprint = song.fileFingerprint?.cacheKey,
                  let analysis = analyses[fingerprint] else {
                return song
            }
            var enriched = song
            enriched.loudness = analysis
            return enriched
        }
    }
}
