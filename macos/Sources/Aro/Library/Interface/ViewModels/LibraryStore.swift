import Foundation
import AroCommon
import Observation

@MainActor
@Observable
final class LibraryStore {
    var selection: Destination? = .home
    private(set) var folders: [WatchedFolder] = []
    private(set) var songsByFolder: [UUID: [Song]] = [:]
    private(set) var scanStates: [UUID: FolderScanState] = [:]
    /// Streaming profiles keep only the server's current catalog page here;
    /// full-mirror profiles continue to use the durable local replica.
    private(set) var serverCatalogSongs: [Song] = []
    private(set) var serverSongsBySource: [UUID: [Song]] = [:]
    private(set) var usesServerCatalog = false
    /// Quality streamed playback asks the hub for. Held here rather than passed through
    /// every call site because it changes independently of the catalog — switching quality
    /// must re-point existing songs, not wait for the next catalog refresh.
    var streamQuality: StreamQuality = .original {
        didSet {
            guard streamQuality != oldValue, usesServerCatalog else { return }
            guard let baseURL = serverBaseURL else { return }
            serverCatalogSongs = serverCatalogSongs.map { song in
                var updated = song
                updated.url = Self.mediaURL(
                    for: song.contentHash,
                    baseURL: baseURL,
                    quality: streamQuality
                )
                return updated
            }
        }
    }
    @ObservationIgnored private var serverBaseURL: URL?

    /// Where a track's audio is fetched from.
    ///
    /// `original` uses the plain blob endpoint. Every other tier goes through the streaming
    /// endpoint, which serves a cached encode when the hub has one and encodes on the fly
    /// when it doesn't — so choosing a quality never leaves a newly-imported track
    /// unplayable while it waits for a conversion pass.
    static func mediaURL(
        for contentHash: String?,
        baseURL: URL,
        quality: StreamQuality
    ) -> URL {
        guard let contentHash else { return baseURL }
        guard quality != .original else {
            return baseURL.appendingPathComponent("v1/blobs/\(contentHash)")
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/blobs/\(contentHash)/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "quality", value: quality.rawValue)]
        return components?.url
            ?? baseURL.appendingPathComponent("v1/blobs/\(contentHash)")
    }
    @ObservationIgnored private var serverArtworkByHash: [String: Data] = [:]

    @ObservationIgnored private let manageFolders: ManageWatchedFolders
    @ObservationIgnored private let folderAccess: any FolderAccessing
    @ObservationIgnored private let legacyFolders:
        any LegacyWatchedFolderStoring

    init(
        manageFolders: ManageWatchedFolders,
        folderAccess: any FolderAccessing,
        legacyFolders: any LegacyWatchedFolderStoring
    ) {
        self.manageFolders = manageFolders
        self.folderAccess = folderAccess
        self.legacyFolders = legacyFolders
        restoreFolders()
    }

    var visibleSongs: [Song] {
        if usesServerCatalog {
            if case .folder(let id) = selection {
                return serverSongsBySource[id] ?? []
            }
            return serverCatalogSongs
        }
        switch selection {
        case .folder(let id):
            return songsByFolder[id] ?? []
        case .home, .songs, .artists, .albums, .stats, .libraryHealth, .settings, .metadata, .none:
            return SongLibrary.aggregate(songsByFolder)
        }
    }

    var allSongs: [Song] {
        if usesServerCatalog {
            return serverCatalogSongs
        }
        return SongLibrary.aggregate(songsByFolder)
    }

    func songsExcludingFolder(id: UUID) -> [Song] {
        if usesServerCatalog {
            let removed = Set(
                (serverSongsBySource[id] ?? []).map(\.libraryID)
            )
            return serverCatalogSongs.filter {
                !removed.contains($0.libraryID)
            }
        }
        return SongLibrary.aggregate(
            songsByFolder.filter { $0.key != id }
        )
    }

    /// Installs a lightweight server page as the active read model. The media
    /// URL remains server-backed; audio bytes are still resolved by the normal
    /// playback/cache pipeline only when a track is played or downloaded.
    func setServerCatalog(
        _ tracks: [CatalogTrack],
        baseURL: URL,
        artworkByHash: [String: Data] = [:],
        pendingMetadata: [UUID: [ManualMetadataEdit]] = [:],
        pendingArtwork: [UUID: ManualArtworkEdit] = [:]
    ) {
        serverArtworkByHash.merge(artworkByHash) { _, newest in newest }
        serverBaseURL = baseURL
        serverCatalogSongs = tracks.map { track in
            let mediaURL = Self.mediaURL(
                for: track.contentHash,
                baseURL: baseURL,
                quality: streamQuality
            )
            let song = Song(
                libraryID: track.trackID,
                url: mediaURL,
                title: track.title,
                artist: track.artist ?? "Unknown Artist",
                album: track.album,
                genre: track.genre,
                releaseYear: track.releaseYear.map(Int.init),
                trackNumber: track.trackNumber.map(Int.init),
                discNumber: track.discNumber.map(Int.init),
                artworkData: track.artworkHash.flatMap { serverArtworkByHash[$0] },
                duration: track.durationSeconds,
                fileSizeBytes: track.byteCount.flatMap(Int64.init),
                audioProperties: track.codec.map {
                    AudioFileProperties(
                        codec: $0,
                        sampleRate: track.sampleRate,
                        bitDepth: track.bitDepth.map(Int.init),
                        channelCount: track.channelCount.map(Int.init),
                        bitrate: track.bitrate
                    )
                },
                contentHash: track.contentHash,
                isFavourite: track.favourite ?? false,
                loudness: track.integratedLufs.flatMap { integratedLUFS in
                    guard let peakAmplitude = track.peakAmplitude else { return nil }
                    return LoudnessAnalysis(
                        integratedLUFS: integratedLUFS,
                        peakAmplitude: peakAmplitude,
                        analyzedAt: track.loudnessAnalyzedAt
                            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
                        algorithmVersion: track.loudnessAlgorithmVersion.map(Int.init)
                            ?? LoudnessAnalysis.remoteAlgorithmVersion
                    )
                }
            )
            return Self.applying(
                pendingMetadata[track.trackID] ?? [],
                artwork: pendingArtwork[track.trackID],
                to: song
            )
        }
        serverSongsBySource = [:]
        for (track, song) in zip(tracks, serverCatalogSongs) {
            if let sourceID = track.sourceID {
                serverSongsBySource[sourceID, default: []].append(song)
            }
        }
        let existingSourceIDs = Set(folders.map(\.id))
        let derivedSources = Dictionary(
            grouping: tracks.compactMap { track in
                track.sourceID.map { ($0, track.sourceName) }
            },
            by: { $0.0 }
        )
        for (sourceID, rows) in derivedSources
        where !existingSourceIDs.contains(sourceID) {
            folders.append(
                serverFolder(
                    id: sourceID,
                    name: rows.compactMap { $0.1 }.first ?? "Imported Music",
                    available: true
                )
            )
        }
        usesServerCatalog = true
    }

    func setServerSources(_ sources: [SourceHealthReport]) {
        let reportedIDs = Set(sources.map(\.sourceID))
        let derived = folders.filter {
            serverSongsBySource[$0.id] != nil && !reportedIDs.contains($0.id)
        }
        folders = (sources.map { source in
            serverFolder(
                id: source.sourceID,
                name: source.name,
                available: source.available
            )
        } + derived).sorted {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
        scanStates = Dictionary(uniqueKeysWithValues: sources.map { source in
            (
                source.sourceID,
                source.available
                    ? FolderScanState.idle
                    : FolderScanState.warning(
                        source.warning ?? "The server cannot reach this source."
                    )
            )
        })
    }

    private func serverFolder(
        id: UUID,
        name: String,
        available: Bool
    ) -> WatchedFolder {
        WatchedFolder(
            id: id,
            url: URL(string: "aro-server-source://\(id.uuidString)")!,
            displayName: name,
            bookmarkData: nil,
            isAccessible: available,
            didStartSecurityScope: false
        )
    }

    func missingServerArtworkHashes(for tracks: [CatalogTrack]) -> [String] {
        Array(Set(tracks.compactMap(\.artworkHash)))
            .filter { serverArtworkByHash[$0] == nil }
    }

    func clearServerCatalog() {
        serverCatalogSongs = []
        serverSongsBySource = [:]
        serverArtworkByHash = [:]
        usesServerCatalog = false
    }

    func reflectFavourite(trackID: UUID, favourite: Bool) {
        guard usesServerCatalog else {
            reloadStoredLibrary()
            return
        }
        serverCatalogSongs = serverCatalogSongs.map { song in
            guard song.libraryID == trackID else { return song }
            return Song(
                libraryID: song.libraryID,
                url: song.url,
                title: song.title,
                artist: song.artist,
                album: song.album,
                genre: song.genre,
                releaseYear: song.releaseYear,
                trackNumber: song.trackNumber,
                discNumber: song.discNumber,
                artworkData: song.artworkData,
                duration: song.duration,
                fileSizeBytes: song.fileSizeBytes,
                audioProperties: song.audioProperties,
                fileFingerprint: song.fileFingerprint,
                contentHash: song.contentHash,
                isFavourite: favourite,
                loudness: song.loudness,
                musicbrainzGenres: song.musicbrainzGenres,
                moodTags: song.moodTags
            )
        }
    }

    func reflectServerRemoval(trackID: UUID) {
        guard usesServerCatalog else { return }
        serverCatalogSongs.removeAll { $0.libraryID == trackID }
        for sourceID in serverSongsBySource.keys {
            serverSongsBySource[sourceID]?.removeAll {
                $0.libraryID == trackID
            }
        }
    }

    func metadataSnapshot(for song: Song) -> TrackMetadataSnapshot {
        manageFolders.metadataSnapshot(song: song, librarySongs: allSongs)
    }

    func applyManualMetadata(
        _ edits: [ManualMetadataEdit],
        artwork: ManualArtworkEdit?,
        to songs: [Song]
    ) {
        guard (!edits.isEmpty || artwork != nil), !songs.isEmpty else { return }
        let trackIDs = songs.map(\.libraryID)
        if usesServerCatalog {
            if !edits.isEmpty {
                manageFolders.queueManualMetadata(edits, trackIDs: trackIDs, reset: false)
            }
            if let artwork {
                manageFolders.queueManualArtwork(artwork, trackIDs: trackIDs)
            }
            let editedIDs = Set(songs.map(\.libraryID))
            serverCatalogSongs = serverCatalogSongs.map { song in
                editedIDs.contains(song.libraryID)
                    ? Self.applying(edits, artwork: artwork, to: song)
                    : song
            }
        } else {
            if !edits.isEmpty {
                manageFolders.applyManualMetadata(edits, trackIDs: trackIDs)
            }
            if let artwork {
                manageFolders.applyManualArtwork(artwork, trackIDs: trackIDs)
            }
            reloadStoredLibrary()
        }
    }

    func resetManualMetadata(for songs: [Song]) {
        guard !songs.isEmpty else { return }
        if usesServerCatalog {
            manageFolders.queueManualMetadata(
                [],
                trackIDs: songs.map(\.libraryID),
                reset: true
            )
        } else {
            manageFolders.resetManualMetadata(trackIDs: songs.map(\.libraryID))
        }
        // A server-catalog page has no lower layers in memory to restore. Reload
        // it on the next catalog refresh; local/full-mirror libraries can resolve
        // scanner and identification values immediately from SQLite.
        if !usesServerCatalog {
            reloadStoredLibrary()
        }
    }

    private static func applying(
        _ edits: [ManualMetadataEdit],
        artwork: ManualArtworkEdit? = nil,
        to song: Song
    ) -> Song {
        var values = Dictionary(uniqueKeysWithValues: edits.map { ($0.field, $0.value) })
        func text(_ field: EditableMetadataField, fallback: String?) -> String? {
            guard let edit = values.removeValue(forKey: field) else { return fallback }
            return edit?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func integer(_ field: EditableMetadataField, fallback: Int?) -> Int? {
            guard let edit = values.removeValue(forKey: field) else { return fallback }
            return edit.flatMap(Int.init)
        }
        return Song(
            libraryID: song.libraryID,
            url: song.url,
            title: text(.title, fallback: song.title) ?? "Unknown",
            artist: text(.artist, fallback: song.artist) ?? "Unknown Artist",
            album: text(.album, fallback: song.album),
            genre: text(.genre, fallback: song.genre),
            releaseYear: integer(.releaseYear, fallback: song.releaseYear),
            trackNumber: integer(.trackNumber, fallback: song.trackNumber),
            discNumber: integer(.discNumber, fallback: song.discNumber),
            artworkData: artwork.map(\.data) ?? song.artworkData,
            duration: song.duration,
            fileSizeBytes: song.fileSizeBytes,
            audioProperties: song.audioProperties,
            fileFingerprint: song.fileFingerprint,
            contentHash: song.contentHash,
            isFavourite: song.isFavourite,
            loudness: song.loudness,
            musicbrainzGenres: song.musicbrainzGenres,
            moodTags: song.moodTags
        )
    }

    var selectedTitle: String {
        switch selection {
        case .folder(let id):
            return folders.first(where: { $0.id == id })?.displayName ?? "Songs"
        case .home:
            return "Home"
        case .stats:
            return "Stats"
        case .artists:
            return "Artists"
        case .albums:
            return "Albums"
        case .libraryHealth:
            return "Library Health"
        case .settings:
            return "Settings"
        case .metadata:
            return "Metadata"
        case .songs, .none:
            return "Songs"
        }
    }

    var selectedScanState: FolderScanState {
        switch selection {
        case .folder(let id):
            return scanStates[id] ?? .idle
        case .home, .songs, .artists, .albums, .stats, .libraryHealth, .settings, .metadata, .none:
            if scanStates.values.contains(.scanning) {
                return .scanning
            }

            let warningCount = scanStates.values.filter {
                if case .warning = $0 {
                    return true
                }
                return false
            }.count

            return warningCount > 0
                ? .warning("\(warningCount) watched folder(s) could not be fully scanned.")
                : .idle
        }
    }

    func reloadStoredLibrary() {
        for folder in folders {
            songsByFolder[folder.id] = manageFolders.storedSongs(
                folderID: folder.id
            )
        }
    }

    /// Re-reads `folders` from the database and reloads every folder's songs —
    /// unlike `reloadStoredLibrary()`, which only refreshes songs for folders
    /// already known in memory. Needed after `LocalHubReplicaCoordinator`
    /// writes a new synthetic "folder" row for the local hub directly via SQL,
    /// bypassing `addFolder`'s in-memory bookkeeping entirely.
    func refreshFoldersFromDatabase() {
        restoreFolders()
    }

    /// Merges background AcoustID/MusicBrainz identification results (pulled from
    /// `aro-server`'s control socket, keyed by content hash) into the local catalog,
    /// then reloads so Songs/Artists/Albums reflect them. Artwork is a reference on
    /// the wire rather than embedded bytes, so it's fetched here — best-effort; a
    /// failed or missing download just means no artwork this round, not a failed
    /// identification. `resolveBlobHash` fetches a hub-cached artwork blob (see
    /// `downloadArtwork` below) — the caller supplies it since this class doesn't
    /// own a control-socket client itself.
    func applyIdentificationResults(
        _ results: [IdentificationResult],
        resolveBlobHash: (String) async -> Data?
    ) async {
        guard !results.isEmpty else { return }
        let manageFolders = manageFolders
        var appliedAny = false
        for result in results {
            let artworkData = await Self.downloadArtwork(
                result.artworkURL,
                resolveBlobHash: resolveBlobHash
            )
            // Hops the SQLite write off the main actor — this loop can run
            // over many results per poll and would otherwise block the UI.
            let applied = await Task.detached(priority: .utility) {
                manageFolders.applyIdentification(
                    contentHash: result.contentHash,
                    title: result.title,
                    artist: result.artist,
                    album: result.album,
                    musicbrainzRecordingID: result.musicbrainzRecordingID,
                    acoustidID: result.acoustidID,
                    artworkData: artworkData,
                    musicbrainzGenresJSON: result.musicbrainzGenres,
                    moodTagsJSON: result.moodTags
                )
            }.value
            appliedAny = appliedAny || applied
        }
        if appliedAny {
            reloadStoredLibrary()
        }
    }

    /// Fills in artwork bytes for tracks that learned an artwork reference through
    /// a *synced track operation* rather than the identification-results
    /// control-socket pull. That pull only ever has data on a machine actually
    /// running identification (a host with its own `aro-server`); a pure remote
    /// client only ever learns title/artist/album/artwork through normal CRDT
    /// sync, which is why this exists as a separate path from
    /// `applyIdentificationResults` above. `resolveBlobHash` here is expected to
    /// fetch from the *remote* hub (authenticated, pinned-TLS) rather than a local
    /// control socket — see `downloadArtwork`.
    func downloadPendingArtwork(resolveBlobHash: (String) async -> Data?) async {
        let manageFolders = manageFolders
        let pending = await Task.detached(priority: .utility) {
            manageFolders.pendingArtworkDownloads(limit: 20)
        }.value
        guard !pending.isEmpty else { return }
        var downloadedAny = false
        for item in pending {
            guard let data = await Self.downloadArtwork(
                item.artworkURL,
                resolveBlobHash: resolveBlobHash
            ) else { continue }
            // Hops the SQLite write off the main actor — this loop can run
            // over many items per poll and would otherwise block the UI.
            await Task.detached(priority: .utility) {
                manageFolders.storeArtwork(trackID: item.trackID, data: data)
            }.value
            downloadedAny = true
        }
        if downloadedAny {
            reloadStoredLibrary()
        }
    }

    /// Artwork is always resolved through the library server's content-addressed
    /// blob store. Legacy third-party URLs are deliberately not fetched by clients;
    /// the server owns external enrichment and migration.
    private static func downloadArtwork(
        _ urlString: String?,
        resolveBlobHash: (String) async -> Data?
    ) async -> Data? {
        guard let urlString else { return nil }
        if let hash = blobHash(from: urlString) {
            return await resolveBlobHash(hash)
        }
        return nil
    }

    private static let blobURLPrefix = "/v1/blobs/"

    private static func blobHash(from urlString: String) -> String? {
        guard urlString.hasPrefix(blobURLPrefix) else { return nil }
        return String(urlString.dropFirst(blobURLPrefix.count))
    }

    func removeFolder(id: UUID) {
        if let folder = folders.first(where: { $0.id == id }),
           folder.didStartSecurityScope {
            folderAccess.endAccessing(folder.url)
        }

        songsByFolder[id] = nil
        scanStates[id] = nil
        folders.removeAll { $0.id == id }
        manageFolders.remove(folderID: id)

        if selection == .folder(id) {
            selection = .songs
        }

        persistFolders()
    }

    /// Relocates a folder's on-disk location/security-scoped bookmark and
    /// persists it. Scanning itself is never triggered from here: every
    /// folder's content comes from its own hub (`LocalHubReplicaCoordinator`
    /// for the local hub, `HubSyncCoordinator` for a remote one), not from
    /// this app scanning the relocated path directly.
    func relocateFolder(id: UUID, to selectedURL: URL) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        let oldFolder = folders[index]
        let url = folderAccess.normalizedURL(selectedURL)
        guard folderAccess.isAccessibleDirectory(url) else {
            scanStates[id] = .warning("The selected folder is unavailable.")
            return
        }

        if oldFolder.didStartSecurityScope {
            folderAccess.endAccessing(oldFolder.url)
        }

        let relocated = WatchedFolder(
            id: id,
            url: url,
            displayName: url.lastPathComponent,
            bookmarkData: folderAccess.bookmarkData(for: url),
            isAccessible: true,
            didStartSecurityScope: folderAccess.beginAccessing(url)
        )
        folders[index] = relocated
        folders.sort {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
        scanStates[id] = .idle
        persistFolders()
    }

    private func restoreFolders() {
        let databaseRecords = manageFolders.storedFolders()
        let records: [StoredWatchedFolder]
        if !databaseRecords.isEmpty {
            records = databaseRecords
        } else {
            records = legacyFolders.load()
        }

        folders = records.map { record in
            if let remoteURL = URL(string: record.path),
               ["http", "https", "aro-local-hub"].contains(
                remoteURL.scheme?.lowercased() ?? ""
               ) {
                return WatchedFolder(
                    id: record.id,
                    url: remoteURL,
                    displayName: record.displayName,
                    bookmarkData: nil,
                    isAccessible: true,
                    didStartSecurityScope: false
                )
            }
            let access = folderAccess.resolve(
                path: record.path,
                bookmarkData: record.bookmarkData
            )

            return WatchedFolder(
                id: record.id,
                url: access.url,
                displayName: record.displayName,
                bookmarkData: access.bookmarkData,
                isAccessible: folderAccess.isAccessibleDirectory(
                    access.url
                ),
                didStartSecurityScope: access.didStartSecurityScope
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        for folder in folders {
            scanStates[folder.id] = folder.isAccessible
                ? .idle
                : .warning("This folder is unavailable.")
            songsByFolder[folder.id] = manageFolders.storedSongs(
                folderID: folder.id
            )
        }

        if records.count != folders.count
            || folders.contains(where: { $0.bookmarkData != nil }) {
            persistFolders()
        } else {
            for folder in folders {
                manageFolders.save(folder)
            }
        }
    }

    private func persistFolders() {
        for folder in folders {
            manageFolders.save(folder)
        }

        let records = folders.map {
            StoredWatchedFolder(
                id: $0.id,
                displayName: $0.displayName,
                path: persistedLocation(for: $0.url),
                bookmarkData: $0.bookmarkData
            )
        }

        legacyFolders.save(records)
    }

    private func persistedLocation(for url: URL) -> String {
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url.absoluteString
        }
        return url.path
    }

}
