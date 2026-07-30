import Foundation
import AroCommon

/// A track whose artwork URL arrived via a synced track operation but whose image
/// bytes haven't been downloaded yet.
struct PendingArtwork: Sendable {
    let trackID: String
    let artworkURL: String
}

protocol LibraryCatalogRepository: Sendable {
    func watchedFolders() -> [StoredWatchedFolder]
    func save(folder: WatchedFolder)
    func removeFolder(id: UUID)
    func markFolderUnavailable(id: UUID)
    func songs(folderID: UUID) -> [Song]
    func reconcile(songs: [Song], folderID: UUID) -> [Song]

    /// Merges a background AcoustID/MusicBrainz identification result into the
    /// catalog, keyed by content hash. Returns `false` if no local song has this
    /// content hash.
    @discardableResult
    func applyIdentification(
        contentHash: String,
        title: String?,
        artist: String?,
        album: String?,
        musicbrainzRecordingID: String?,
        acoustidID: String?,
        artworkData: Data?
    ) -> Bool

    /// Tracks that learned an artwork URL through a synced track operation (rather
    /// than the identification-results control-socket pull, which only has data on
    /// a machine actually running identification) but don't have the image bytes
    /// downloaded yet.
    func pendingArtworkDownloads(limit: Int) -> [PendingArtwork]

    func storeArtwork(trackID: String, data: Data)
}
