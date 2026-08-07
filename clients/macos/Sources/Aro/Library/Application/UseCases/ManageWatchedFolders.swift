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

    func metadataSnapshot(song: Song, librarySongs: [Song]) -> TrackMetadataSnapshot {
        catalog.metadataSnapshot(song: song, librarySongs: librarySongs)
    }

    func applyManualMetadata(_ edits: [ManualMetadataEdit], trackIDs: [UUID]) {
        catalog.applyManualMetadata(edits, trackIDs: trackIDs)
    }

    func applyManualArtwork(_ edit: ManualArtworkEdit, trackIDs: [UUID]) {
        catalog.applyManualArtwork(edit, trackIDs: trackIDs)
    }

    func resetManualMetadata(trackIDs: [UUID]) {
        catalog.resetManualMetadata(trackIDs: trackIDs)
    }

    func queueManualMetadata(
        _ edits: [ManualMetadataEdit],
        trackIDs: [UUID],
        reset: Bool
    ) {
        catalog.queueManualMetadata(edits, trackIDs: trackIDs, reset: reset)
    }

    func queueManualArtwork(_ edit: ManualArtworkEdit, trackIDs: [UUID]) {
        catalog.queueManualArtwork(edit, trackIDs: trackIDs)
    }
}
