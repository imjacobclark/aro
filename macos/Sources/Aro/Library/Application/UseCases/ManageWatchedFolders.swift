import Foundation
import AroCommon

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

    @discardableResult
    func applyIdentification(
        contentHash: String,
        title: String?,
        artist: String?,
        album: String?,
        musicbrainzRecordingID: String?,
        acoustidID: String?,
        artworkData: Data?,
        musicbrainzGenresJSON: String? = nil,
        moodTagsJSON: String? = nil
    ) -> Bool {
        catalog.applyIdentification(
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
        catalog.pendingArtworkDownloads(limit: limit)
    }

    func storeArtwork(trackID: String, data: Data) {
        catalog.storeArtwork(trackID: trackID, data: data)
    }
}
