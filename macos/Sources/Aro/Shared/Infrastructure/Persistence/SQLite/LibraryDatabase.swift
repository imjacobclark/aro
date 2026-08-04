import Foundation
import AroCommon
import CryptoKit
import SQLite3

struct DatabaseFolderRecord: Sendable {
    let id: UUID
    let displayName: String
    let path: String
    let bookmarkData: Data?
}

/// SQLite is opened in full-mutex mode and every handle access is serialized
/// by `lock`, which is why this reference type can cross task boundaries.
final class LibraryDatabase: @unchecked Sendable {
    let url: URL
    let deviceID: UUID

    private let lock = NSRecursiveLock()
    private var connection: OpaquePointer?

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()

        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "library.deviceID"),
           let id = UUID(uuidString: stored) {
            deviceID = id
        } else {
            let id = UUID()
            deviceID = id
            defaults.set(id.uuidString, forKey: "library.deviceID")
        }

        do {
            try FileManager.default.createDirectory(
                at: self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(
                self.url.path,
                &opened,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let opened else {
                if let opened {
                    sqlite3_close(opened)
                }
                return
            }
            connection = opened
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try SQLiteSchemaMigrator(connection: opened).migrate()
            try registerLocalDevice()
        } catch {
            if let connection {
                sqlite3_close(connection)
                self.connection = nil
            }
        }
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    var isAvailable: Bool {
        lock.withLock { connection != nil }
    }

    func withReadConnection<Value>(
        _ operation: (OpaquePointer) -> Value
    ) -> Value? {
        withConnection(operation)
    }

    func withConnection<Value>(
        _ operation: (OpaquePointer) -> Value
    ) -> Value? {
        lock.withLock {
            guard let connection else {
                return nil
            }
            return operation(connection)
        }
    }

    func watchedFolders() -> [DatabaseFolderRecord] {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT id, display_name, path, bookmark
                FROM watched_folders
                WHERE removed_at IS NULL
                ORDER BY display_name COLLATE NOCASE
                """
            ) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var records: [DatabaseFolderRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = text(statement, 0),
                      let id = UUID(uuidString: idString),
                      let displayName = text(statement, 1),
                      let path = text(statement, 2) else {
                    continue
                }
                records.append(
                    DatabaseFolderRecord(
                        id: id,
                        displayName: displayName,
                        path: path,
                        bookmarkData: blob(statement, 3)
                    )
                )
            }
            return records
        }
    }

    func save(folder: WatchedFolder) {
        lock.withLock {
            guard let statement = try? prepare(
                """
                INSERT INTO watched_folders
                    (id, display_name, path, bookmark, added_at, removed_at)
                VALUES (?, ?, ?, ?, ?, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    path = excluded.path,
                    bookmark = excluded.bookmark,
                    removed_at = NULL
                """
            ) else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(folder.id.uuidString, to: statement, at: 1)
            bind(folder.displayName, to: statement, at: 2)
            bind(
                Self.persistedLocation(for: folder.url),
                to: statement,
                at: 3
            )
            bind(folder.bookmarkData, to: statement, at: 4)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            _ = sqlite3_step(statement)
        }
    }

    private static func persistedLocation(for url: URL) -> String {
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url.absoluteString
        }
        return url.standardizedFileURL.path
    }

    func removeFolder(id: UUID) {
        lock.withLock {
            do {
                try transaction {
                    let now = Date().timeIntervalSince1970
                    try run(
                        "UPDATE watched_folders SET removed_at = ? WHERE id = ?"
                    ) {
                        sqlite3_bind_double($0, 1, now)
                        bind(id.uuidString, to: $0, at: 2)
                    }
                    try run(
                        """
                        UPDATE file_locations
                        SET available = 0, updated_at = ?
                        WHERE folder_id = ? AND device_id = ?
                        """
                    ) {
                        sqlite3_bind_double($0, 1, now)
                        bind(id.uuidString, to: $0, at: 2)
                        bind(deviceID.uuidString, to: $0, at: 3)
                    }
                    try appendChange(
                        entityType: "folder",
                        entityID: id.uuidString,
                        operation: "remove",
                        payload: "{}"
                    )
                }
            } catch {
                return
            }
        }
    }

    func markFolderUnavailable(id: UUID) {
        lock.withLock {
            try? run(
                """
                UPDATE file_locations
                SET available = 0, updated_at = ?
                WHERE folder_id = ? AND device_id = ?
                """
            ) {
                sqlite3_bind_double($0, 1, Date().timeIntervalSince1970)
                bind(id.uuidString, to: $0, at: 2)
                bind(deviceID.uuidString, to: $0, at: 3)
            }
        }
    }

    func songs(folderID: UUID) -> [Song] {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT t.id, l.path,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'title'
                       ) THEN (
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'title'
                       ) ELSE COALESCE(ts.title_override, sm.title) END,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'artist'
                       ) THEN (
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'artist'
                       ) ELSE COALESCE(ts.artist_override, sm.artist) END,
                       sm.duration,
                       l.file_size, sm.codec, sm.sample_rate, sm.bit_depth,
                       sm.channel_count, sm.bitrate, l.modification_date,
                       t.content_hash, la.integrated_lufs, la.peak_amplitude,
                       la.analyzed_at, la.algorithm_version,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'album'
                       ) THEN (
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'album'
                       ) ELSE COALESCE(ts.album_override, sm.album) END,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'genre'
                       ) THEN (
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'genre'
                       ) ELSE sm.genre END,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'release_year'
                       ) THEN CAST((
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'release_year'
                       ) AS INTEGER) ELSE sm.release_year END,
                       CASE WHEN ts.manual_artwork_set = 1
                           THEN ts.manual_artwork
                           ELSE COALESCE(ts.identified_artwork, sm.artwork)
                       END, ts.favourite,
                       ts.mb_genres_json, ts.mood_tags_json,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'track_number'
                       ) THEN CAST((
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'track_number'
                       ) AS INTEGER) ELSE sm.track_number END,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'disc_number'
                       ) THEN CAST((
                           SELECT value FROM manual_metadata_overrides mo
                           WHERE mo.track_id = t.id AND mo.field = 'disc_number'
                       ) AS INTEGER) ELSE sm.disc_number END
                FROM file_locations AS l
                JOIN tracks AS t ON t.id = l.track_id
                JOIN scan_metadata AS sm ON sm.track_id = t.id
                JOIN track_state AS ts ON ts.track_id = t.id
                LEFT JOIN loudness_analysis AS la
                  ON la.fingerprint = t.content_hash
                 AND la.algorithm_version = CASE
                     WHEN l.path LIKE 'http://%'
                       OR l.path LIKE 'https://%'
                     THEN ?
                     ELSE ?
                 END
                WHERE l.folder_id = ?
                  AND l.device_id = ?
                  AND l.available = 1
                  AND ts.hidden = 0
                  AND ts.deleted_at IS NULL
                  AND (
                    (l.path NOT LIKE 'http://%'
                     AND l.path NOT LIKE 'https://%')
                    OR la.fingerprint IS NOT NULL
                  )
                """
            ) else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(
                statement,
                1,
                Int32(LoudnessAnalysis.remoteAlgorithmVersion)
            )
            sqlite3_bind_int(
                statement,
                2,
                Int32(LoudnessAnalysis.algorithmVersion)
            )
            bind(folderID.uuidString, to: statement, at: 3)
            bind(deviceID.uuidString, to: statement, at: 4)

            var songs: [Song] = []
            // Scan metadata stores the embedded picture per track. Keeping an
            // independent `Data` allocation for every track of an album makes
            // a large library consume gigabytes before any artwork is drawn.
            // Reuse the first payload for an artist/album pair; this also
            // matches the artwork selection policy used by AlbumLibrary.
            var artworkByAlbum: [String: Data] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = text(statement, 0),
                      let id = UUID(uuidString: idString),
                      let path = text(statement, 1) else {
                    continue
                }

                let contentHash = text(statement, 12)
                let isRemotePath = URL(string: path).map {
                    ["http", "https"].contains(
                        $0.scheme?.lowercased() ?? ""
                    )
                } ?? false
                let fileSize = optionalInt64(statement, 5)
                let modificationDate = optionalDouble(statement, 11).map {
                    Date(timeIntervalSince1970: $0)
                } ?? (isRemotePath ? .distantPast : nil)
                let fingerprint = fileSize.flatMap { size in
                    modificationDate.map {
                        AudioFileFingerprint(
                            standardizedPath: path,
                            fileSizeBytes: size,
                            modificationDate: $0,
                            contentHash: contentHash
                        )
                    }
                }
                let properties = text(statement, 6).map {
                    AudioFileProperties(
                        codec: $0,
                        sampleRate: optionalDouble(statement, 7),
                        bitDepth: optionalInt(statement, 8),
                        channelCount: optionalInt(statement, 9),
                        bitrate: optionalDouble(statement, 10)
                    )
                }
                let loudness: LoudnessAnalysis?
                if sqlite3_column_type(statement, 13) != SQLITE_NULL {
                    loudness = LoudnessAnalysis(
                        integratedLUFS: sqlite3_column_double(statement, 13),
                        peakAmplitude: sqlite3_column_double(statement, 14),
                        analyzedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                15
                            )
                        ),
                        algorithmVersion: optionalInt(statement, 16)
                            ?? LoudnessAnalysis.algorithmVersion
                    )
                } else {
                    loudness = nil
                }

                let url = URL(string: path).flatMap {
                    ["http", "https"].contains($0.scheme?.lowercased() ?? "")
                        ? $0
                        : nil
                } ?? URL(fileURLWithPath: path)
                let artist = text(statement, 3) ?? "—"
                let album = text(statement, 17)
                let artworkKey = artist + "\u{1F}" + (album ?? "")
                let artworkData: Data?
                if let existing = artworkByAlbum[artworkKey] {
                    artworkData = existing
                } else if let artwork = blob(statement, 20) {
                    artworkByAlbum[artworkKey] = artwork
                    artworkData = artwork
                } else {
                    artworkData = nil
                }
                songs.append(
                    Song(
                        libraryID: id,
                        url: url,
                        title: text(statement, 2) ?? "Unknown",
                        artist: artist,
                        album: album,
                        genre: text(statement, 18),
                        releaseYear: optionalInt(statement, 19),
                        trackNumber: optionalInt(statement, 24),
                        discNumber: optionalInt(statement, 25),
                        artworkData: artworkData,
                        duration: optionalDouble(statement, 4),
                        fileSizeBytes: fileSize,
                        audioProperties: properties,
                        fileFingerprint: fingerprint,
                        contentHash: contentHash,
                        isFavourite:
                            sqlite3_column_int(statement, 21) != 0,
                        loudness: loudness,
                        musicbrainzGenres: stringArray(
                            from: text(statement, 22)
                        ),
                        moodTags: stringArray(from: text(statement, 23))
                    )
                )
            }
            return SongLibrary.deduplicated(songs)
        }
    }

    func reconcile(songs: [Song], folderID: UUID) -> [Song] {
        lock.withLock {
            guard connection != nil else {
                return songs
            }

            let scanToken = UUID().uuidString
            var reconciled: [Song] = []
            do {
                try transaction {
                    for song in songs {
                        let trackID = try resolveTrackID(for: song)
                        try upsert(trackID: trackID, song: song)
                        try upsertLocation(
                            trackID: trackID,
                            song: song,
                            folderID: folderID,
                            scanToken: scanToken
                        )

                        guard try !isHidden(trackID: trackID) else {
                            continue
                        }
                        let favourite = try isFavourite(trackID: trackID)
                        let tags = try moodAndGenreTags(trackID: trackID)
                        reconciled.append(
                            Song(
                                libraryID: trackID,
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
                                musicbrainzGenres: tags.genres,
                                moodTags: tags.moods
                            )
                        )
                    }

                    try run(
                        """
                        UPDATE file_locations
                        SET available = 0, updated_at = ?
                        WHERE folder_id = ?
                          AND device_id = ?
                          AND last_seen_token <> ?
                        """
                    ) {
                        sqlite3_bind_double($0, 1, Date().timeIntervalSince1970)
                        bind(folderID.uuidString, to: $0, at: 2)
                        bind(deviceID.uuidString, to: $0, at: 3)
                        bind(scanToken, to: $0, at: 4)
                    }
                }
                // Re-read through the normal effective-metadata query so a
                // filesystem rescan cannot briefly surface scanner values over
                // an existing manual golden master.
                return self.songs(folderID: folderID)
            } catch {
                return songs
            }
        }
    }

    func pendingArtworkDownloads(limit: Int) -> [PendingArtwork] {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT sm.track_id,
                       CASE WHEN ts.manual_artwork_set = 1
                           THEN ts.manual_artwork_url
                           ELSE COALESCE(ts.identified_artwork_url, sm.artwork_url) END
                FROM scan_metadata sm
                JOIN track_state ts ON ts.track_id = sm.track_id
                WHERE CASE WHEN ts.manual_artwork_set = 1
                    THEN ts.manual_artwork_url IS NOT NULL
                         AND ts.manual_artwork IS NULL
                    ELSE COALESCE(ts.identified_artwork_url, sm.artwork_url) IS NOT NULL
                         AND ts.identified_artwork IS NULL END
                LIMIT ?
                """
            ) else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var results: [PendingArtwork] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let trackID = text(statement, 0),
                      let url = text(statement, 1) else {
                    continue
                }
                results.append(PendingArtwork(trackID: trackID, artworkURL: url))
            }
            return results
        }
    }

    /// Stores downloaded artwork bytes for a track already known locally by id
    /// (unlike `applyIdentification`, which resolves by content hash — this is
    /// called for tracks already found via `pendingArtworkDownloads`).
    func storeArtwork(trackID: String, data: Data) {
        lock.withLock {
            try? run(
                """
                UPDATE track_state
                SET manual_artwork = ?
                WHERE track_id = ? AND manual_artwork_set = 1
                    AND manual_artwork_url IS NOT NULL
                """
            ) {
                bind(data, to: $0, at: 1)
                bind(trackID, to: $0, at: 2)
            }
            try? run(
                """
                UPDATE track_state SET identified_artwork = ?
                WHERE track_id = ? AND manual_artwork_set = 0
                    AND identified_artwork_url IS NOT NULL
                """
            ) {
                bind(data, to: $0, at: 1)
                bind(trackID, to: $0, at: 2)
            }
            try? run(
                """
                UPDATE scan_metadata SET artwork = ?
                WHERE track_id = ? AND NOT EXISTS (
                    SELECT 1 FROM track_state ts
                    WHERE ts.track_id = scan_metadata.track_id
                      AND (ts.manual_artwork_set = 1
                           OR ts.identified_artwork_url IS NOT NULL)
                )
                """
            ) {
                bind(data, to: $0, at: 1)
                bind(trackID, to: $0, at: 2)
            }
        }
    }

    /// Merges a background-identification result (from `aro-server`'s AcoustID/
    /// MusicBrainz pipeline) into `track_state`'s override columns, keyed by content
    /// hash — the only identifier shared between this database and `aro-server`'s own
    /// `hub.sqlite3`, since the two generate track ids independently. Returns `false`
    /// (not an error) if no local track has this content hash yet.
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
        lock.withLock {
            guard let statement = try? prepare(
                "SELECT id FROM tracks WHERE content_hash = ? LIMIT 1"
            ) else {
                return false
            }
            let trackID: String
            do {
                defer { sqlite3_finalize(statement) }
                bind(contentHash, to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let idString = text(statement, 0) else {
                    return false
                }
                trackID = idString
            }

            let now = Date().timeIntervalSince1970
            do {
                try run(
                    """
                    INSERT INTO track_state
                        (track_id, updated_at, title_override, artist_override,
                         album_override, musicbrainz_recording_id, acoustid_id,
                         mb_genres_json, mood_tags_json, identified_artwork)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(track_id) DO UPDATE SET
                        updated_at = excluded.updated_at,
                        title_override =
                            COALESCE(excluded.title_override, track_state.title_override),
                        artist_override =
                            COALESCE(excluded.artist_override, track_state.artist_override),
                        album_override =
                            COALESCE(excluded.album_override, track_state.album_override),
                        musicbrainz_recording_id = COALESCE(
                            excluded.musicbrainz_recording_id,
                            track_state.musicbrainz_recording_id
                        ),
                        acoustid_id =
                            COALESCE(excluded.acoustid_id, track_state.acoustid_id),
                        mb_genres_json =
                            COALESCE(excluded.mb_genres_json, track_state.mb_genres_json),
                        mood_tags_json =
                            COALESCE(excluded.mood_tags_json, track_state.mood_tags_json),
                        identified_artwork = COALESCE(
                            excluded.identified_artwork,
                            track_state.identified_artwork
                        )
                    """
                ) {
                    bind(trackID, to: $0, at: 1)
                    sqlite3_bind_double($0, 2, now)
                    bind(title, to: $0, at: 3)
                    bind(artist, to: $0, at: 4)
                    bind(album, to: $0, at: 5)
                    bind(musicbrainzRecordingID, to: $0, at: 6)
                    bind(acoustidID, to: $0, at: 7)
                    bind(musicbrainzGenresJSON, to: $0, at: 8)
                    bind(moodTagsJSON, to: $0, at: 9)
                    bind(artworkData, to: $0, at: 10)
                }
                return true
            } catch {
                return false
            }
        }
    }

    func metadataSnapshot(song: Song, librarySongs: [Song]) -> TrackMetadataSnapshot {
        lock.withLock {
            var manualFields = Set<EditableMetadataField>()
            var candidates: [EditableMetadataField: [MetadataCandidate]] = [:]
            var artworkCandidates: [ArtworkCandidate] = []
            var manualArtworkSet = false
            var loadedStoredSources = false

            func addArtwork(
                _ data: Data?,
                source: MetadataCandidate.Source,
                artist: String?,
                album: String?
            ) {
                guard let data,
                      !data.isEmpty,
                      data.count <= 10 * 1024 * 1024 else { return }
                let candidate = ArtworkCandidate(
                    data: data,
                    source: source,
                    relatedArtist: artist,
                    relatedAlbum: album
                )
                if !artworkCandidates.contains(candidate) {
                    artworkCandidates.append(candidate)
                }
            }

            func add(
                _ value: String?,
                field: EditableMetadataField,
                source: MetadataCandidate.Source,
                relatedArtist: String? = nil
            ) {
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return }
                let candidate = MetadataCandidate(
                    value: value,
                    source: source,
                    relatedArtist: relatedArtist
                )
                let existing = candidates[field] ?? []
                let sourceCount = existing.lazy.filter {
                    $0.source == source
                        && (field != .album || $0.relatedArtist == relatedArtist)
                }.count
                if !existing.contains(candidate),
                   sourceCount < 20 {
                    candidates[field, default: []].append(candidate)
                }
            }

            if let statement = try? prepare(
                """
                SELECT sm.title, sm.artist, sm.album, sm.genre, sm.release_year,
                       sm.track_number, sm.disc_number,
                       ts.title_override, ts.artist_override, ts.album_override,
                       sm.artwork, ts.identified_artwork,
                       ts.manual_artwork_set, ts.manual_artwork
                FROM tracks t
                LEFT JOIN scan_metadata sm ON sm.track_id = t.id
                LEFT JOIN track_state ts ON ts.track_id = t.id
                WHERE t.id = ?
                """
            ) {
                defer { sqlite3_finalize(statement) }
                bind(song.libraryID.uuidString, to: statement, at: 1)
                if sqlite3_step(statement) == SQLITE_ROW {
                    loadedStoredSources = true
                    let fileArtist = text(statement, 1)
                    let identifiedArtist = text(statement, 8)
                    let fileAlbum = text(statement, 2)
                    let identifiedAlbum = text(statement, 9)
                    add(text(statement, 0), field: .title, source: .file)
                    add(fileArtist, field: .artist, source: .file)
                    add(
                        text(statement, 2),
                        field: .album,
                        source: .file,
                        relatedArtist: fileArtist
                    )
                    add(text(statement, 3), field: .genre, source: .file)
                    add(optionalInt(statement, 4).map(String.init), field: .releaseYear, source: .file)
                    add(optionalInt(statement, 5).map(String.init), field: .trackNumber, source: .file)
                    add(optionalInt(statement, 6).map(String.init), field: .discNumber, source: .file)
                    add(text(statement, 7), field: .title, source: .identified)
                    add(identifiedArtist, field: .artist, source: .identified)
                    add(
                        text(statement, 9),
                        field: .album,
                        source: .identified,
                        relatedArtist: identifiedArtist
                    )
                    addArtwork(
                        blob(statement, 10),
                        source: .file,
                        artist: fileArtist,
                        album: fileAlbum
                    )
                    addArtwork(
                        blob(statement, 11),
                        source: .identified,
                        artist: identifiedArtist,
                        album: identifiedAlbum
                    )
                    manualArtworkSet = sqlite3_column_int(statement, 12) != 0
                    addArtwork(
                        blob(statement, 13),
                        source: .library,
                        artist: song.artist,
                        album: song.album
                    )
                }
            }

            // Streaming-only catalog songs are not materialized in this SQLite
            // database. Their current server-provided cover is the identified
            // candidate, so keep it selectable even without local source rows.
            if !loadedStoredSources {
                add(song.title, field: .title, source: .identified)
                add(song.artist, field: .artist, source: .identified)
                add(
                    song.album,
                    field: .album,
                    source: .identified,
                    relatedArtist: song.artist
                )
                addArtwork(
                    song.artworkData,
                    source: .identified,
                    artist: song.artist,
                    album: song.album
                )
            }

            if let statement = try? prepare(
                "SELECT field FROM manual_metadata_overrides WHERE track_id = ?"
            ) {
                defer { sqlite3_finalize(statement) }
                bind(song.libraryID.uuidString, to: statement, at: 1)
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let raw = text(statement, 0),
                       let field = EditableMetadataField(rawValue: raw) {
                        manualFields.insert(field)
                    }
                }
            }

            for librarySong in librarySongs where librarySong.libraryID != song.libraryID {
                add(librarySong.title, field: .title, source: .library)
                add(librarySong.artist, field: .artist, source: .library)
                add(
                    librarySong.album,
                    field: .album,
                    source: .library,
                    relatedArtist: librarySong.artist
                )
                add(librarySong.genre, field: .genre, source: .library)
                add(librarySong.releaseYear.map(String.init), field: .releaseYear, source: .library)
                addArtwork(
                    librarySong.artworkData,
                    source: .library,
                    artist: librarySong.artist,
                    album: librarySong.album
                )
            }
            return TrackMetadataSnapshot(
                song: song,
                effectiveValues: Self.metadataValues(for: song),
                manualFields: manualFields,
                candidates: candidates,
                artworkCandidates: artworkCandidates,
                manualArtworkSet: manualArtworkSet
            )
        }
    }

    func applyManualMetadata(_ edits: [ManualMetadataEdit], trackIDs: [UUID]) {
        guard !edits.isEmpty, !trackIDs.isEmpty else { return }
        lock.withLock {
            try? transaction {
                let now = Date().timeIntervalSince1970
                for trackID in trackIDs {
                    var syncFields: [String: JSONValue] = [:]
                    for edit in edits {
                        try run(
                            """
                            INSERT INTO manual_metadata_overrides
                                (track_id, field, value, updated_at)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT(track_id, field) DO UPDATE SET
                                value = excluded.value,
                                updated_at = excluded.updated_at
                            """
                        ) {
                            bind(trackID.uuidString, to: $0, at: 1)
                            bind(edit.field.rawValue, to: $0, at: 2)
                            bind(edit.value, to: $0, at: 3)
                            sqlite3_bind_double($0, 4, now)
                        }
                        let key = "manual_\(edit.field.rawValue)"
                        if let value = edit.value {
                            syncFields[key] = edit.field.isNumeric
                                ? Double(value).map(JSONValue.number) ?? .null
                                : .string(value)
                        } else {
                            syncFields[key] = .null
                        }
                        syncFields["\(key)_set"] = .bool(true)
                    }
                    try run("UPDATE track_state SET updated_at = ? WHERE track_id = ?") {
                        sqlite3_bind_double($0, 1, now)
                        bind(trackID.uuidString, to: $0, at: 2)
                    }
                    try appendOutboxOperation(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: "set_metadata",
                        payload: .object(syncFields),
                        now: now
                    )
                }
            }
        }
    }

    func applyManualArtwork(_ edit: ManualArtworkEdit, trackIDs: [UUID]) {
        guard !trackIDs.isEmpty else { return }
        lock.withLock {
            try? transaction {
                let now = Date().timeIntervalSince1970
                for (index, trackID) in trackIDs.enumerated() {
                    try run(
                        """
                        UPDATE track_state
                        SET manual_artwork = ?, manual_artwork_url = NULL,
                            manual_artwork_set = 1, updated_at = ?
                        WHERE track_id = ?
                        """
                    ) {
                        bind(edit.data, to: $0, at: 1)
                        sqlite3_bind_double($0, 2, now)
                        bind(trackID.uuidString, to: $0, at: 3)
                    }
                    try appendOutboxOperation(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: "set_metadata",
                        payload: .object(
                            Self.artworkSyncFields(edit, includeData: index == 0)
                        ),
                        now: now + Double(index) / 1_000
                    )
                }
            }
        }
    }

    func resetManualMetadata(trackIDs: [UUID]) {
        guard !trackIDs.isEmpty else { return }
        lock.withLock {
            try? transaction {
                let now = Date().timeIntervalSince1970
                for trackID in trackIDs {
                    try run("DELETE FROM manual_metadata_overrides WHERE track_id = ?") {
                        bind(trackID.uuidString, to: $0, at: 1)
                    }
                    try run(
                        """
                        UPDATE track_state
                        SET manual_artwork = NULL, manual_artwork_url = NULL,
                            manual_artwork_set = 0, updated_at = ?
                        WHERE track_id = ?
                        """
                    ) {
                        sqlite3_bind_double($0, 1, now)
                        bind(trackID.uuidString, to: $0, at: 2)
                    }
                    var fields = Dictionary(
                        uniqueKeysWithValues: EditableMetadataField.allCases.map {
                            ("manual_\($0.rawValue)_set", JSONValue.bool(false))
                        }
                    )
                    fields["manual_artwork_set"] = .bool(false)
                    try appendOutboxOperation(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: "reset_metadata",
                        payload: .object(fields),
                        now: now
                    )
                }
            }
        }
    }

    /// Streaming-only catalogue rows are intentionally not materialized into the
    /// replica tables, but user intent still needs a durable retry record. This
    /// queues the same server-facing operation without requiring a local track row;
    /// `LibraryStore` owns the optimistic in-memory presentation until the next
    /// server catalogue revision confirms it.
    func queueManualMetadata(
        _ edits: [ManualMetadataEdit],
        trackIDs: [UUID],
        reset: Bool
    ) {
        guard !trackIDs.isEmpty, reset || !edits.isEmpty else { return }
        lock.withLock {
            try? transaction {
                let now = Date().timeIntervalSince1970
                let fields: [String: JSONValue]
                if reset {
                    fields = Dictionary(
                        uniqueKeysWithValues: EditableMetadataField.allCases.map {
                            ("manual_\($0.rawValue)_set", .bool(false))
                        }
                    )
                } else {
                    var values: [String: JSONValue] = [:]
                    for edit in edits {
                        let key = "manual_\(edit.field.rawValue)"
                        if let value = edit.value {
                            values[key] = edit.field.isNumeric
                                ? Double(value).map(JSONValue.number) ?? .null
                                : .string(value)
                        } else {
                            values[key] = .null
                        }
                        values["\(key)_set"] = .bool(true)
                    }
                    fields = values
                }
                for trackID in trackIDs {
                    try appendOutboxOperation(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: reset ? "reset_metadata" : "set_metadata",
                        payload: .object(fields),
                        now: now
                    )
                }
            }
        }
    }

    func queueManualArtwork(
        _ edit: ManualArtworkEdit,
        trackIDs: [UUID]
    ) {
        guard !trackIDs.isEmpty else { return }
        lock.withLock {
            try? transaction {
                let now = Date().timeIntervalSince1970
                for (index, trackID) in trackIDs.enumerated() {
                    try appendOutboxOperation(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: "set_metadata",
                        payload: .object(
                            Self.artworkSyncFields(edit, includeData: index == 0)
                        ),
                        now: now + Double(index) / 1_000
                    )
                }
            }
        }
    }

    private static func artworkSyncFields(
        _ edit: ManualArtworkEdit,
        includeData: Bool
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["manual_artwork_set": .bool(true)]
        if let data = edit.data {
            let hash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            fields["manual_artwork_hash"] = .string(hash)
            if includeData {
                fields["manual_artwork_base64"] = .string(data.base64EncodedString())
            }
        } else {
            fields["manual_artwork_hash"] = .null
        }
        return fields
    }

    private static func metadataValues(for song: Song) -> [EditableMetadataField: String] {
        var values: [EditableMetadataField: String] = [
            .title: song.title,
            .artist: song.artist,
        ]
        values[.album] = song.album ?? ""
        values[.genre] = song.genre ?? ""
        values[.releaseYear] = song.releaseYear.map(String.init) ?? ""
        values[.trackNumber] = song.trackNumber.map(String.init) ?? ""
        values[.discNumber] = song.discNumber.map(String.init) ?? ""
        return values
    }

    private func resolveTrackID(for song: Song) throws -> UUID {
        let path = song.url.standardizedFileURL.path
        if let statement = try? prepare(
            """
            SELECT t.id, t.content_hash
            FROM file_locations AS l
            JOIN tracks AS t ON t.id = l.track_id
            WHERE l.device_id = ? AND l.path = ?
            LIMIT 1
            """
        ) {
            defer { sqlite3_finalize(statement) }
            bind(deviceID.uuidString, to: statement, at: 1)
            bind(path, to: statement, at: 2)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idString = text(statement, 0),
               let id = UUID(uuidString: idString) {
                // A source path is the stable logical identity. Replacing the
                // file updates the same song and preserves ratings/history.
                return id
            }
        }

        if let contentHash = song.fileFingerprint?.contentHash,
           let statement = try? prepare(
               "SELECT id FROM tracks WHERE content_hash = ? LIMIT 1"
           ) {
            defer { sqlite3_finalize(statement) }
            bind(contentHash, to: statement, at: 1)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idString = text(statement, 0),
               let id = UUID(uuidString: idString) {
                return id
            }
        }
        return UUID()
    }

    private func upsert(trackID: UUID, song: Song) throws {
        let now = Date().timeIntervalSince1970
        try run(
            """
            INSERT INTO tracks (id, content_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content_hash = COALESCE(excluded.content_hash, tracks.content_hash),
                updated_at = excluded.updated_at
            """
        ) {
            bind(trackID.uuidString, to: $0, at: 1)
            bind(song.fileFingerprint?.contentHash, to: $0, at: 2)
            sqlite3_bind_double($0, 3, now)
            sqlite3_bind_double($0, 4, now)
        }

        try run(
            """
            INSERT INTO scan_metadata
                (track_id, title, artist, duration, codec, sample_rate,
                 bit_depth, channel_count, bitrate, scanned_at, album, genre,
                 release_year, artwork, track_number, disc_number)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                title = excluded.title,
                artist = excluded.artist,
                duration = excluded.duration,
                codec = excluded.codec,
                sample_rate = excluded.sample_rate,
                bit_depth = excluded.bit_depth,
                channel_count = excluded.channel_count,
                bitrate = excluded.bitrate,
                scanned_at = excluded.scanned_at,
                album = excluded.album,
                genre = excluded.genre,
                release_year = excluded.release_year,
                artwork = excluded.artwork,
                track_number = COALESCE(excluded.track_number, scan_metadata.track_number),
                disc_number = COALESCE(excluded.disc_number, scan_metadata.disc_number)
            """
        ) {
            bind(trackID.uuidString, to: $0, at: 1)
            bind(song.title, to: $0, at: 2)
            bind(song.artist, to: $0, at: 3)
            bind(song.duration, to: $0, at: 4)
            bind(song.audioProperties?.codec, to: $0, at: 5)
            bind(song.audioProperties?.sampleRate, to: $0, at: 6)
            bind(song.audioProperties?.bitDepth, to: $0, at: 7)
            bind(song.audioProperties?.channelCount, to: $0, at: 8)
            bind(song.audioProperties?.bitrate, to: $0, at: 9)
            sqlite3_bind_double($0, 10, now)
            bind(song.album, to: $0, at: 11)
            bind(song.genre, to: $0, at: 12)
            bind(song.releaseYear, to: $0, at: 13)
            bind(song.artworkData, to: $0, at: 14)
            bind(song.trackNumber, to: $0, at: 15)
            bind(song.discNumber, to: $0, at: 16)
        }

        try run(
            """
            INSERT INTO track_state
                (track_id, hidden, favourite, rating, updated_at)
            VALUES (?, 0, 0, NULL, ?)
            ON CONFLICT(track_id) DO NOTHING
            """
        ) {
            bind(trackID.uuidString, to: $0, at: 1)
            sqlite3_bind_double($0, 2, now)
        }
    }

    private func upsertLocation(
        trackID: UUID,
        song: Song,
        folderID: UUID,
        scanToken: String
    ) throws {
        try run(
            """
            INSERT INTO file_locations
                (id, track_id, device_id, folder_id, path, volume_id,
                 file_size, modification_date, available, last_seen_token,
                 updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(device_id, path) DO UPDATE SET
                track_id = excluded.track_id,
                folder_id = excluded.folder_id,
                volume_id = excluded.volume_id,
                file_size = excluded.file_size,
                modification_date = excluded.modification_date,
                available = 1,
                last_seen_token = excluded.last_seen_token,
                updated_at = excluded.updated_at
            """
        ) {
            bind(UUID().uuidString, to: $0, at: 1)
            bind(trackID.uuidString, to: $0, at: 2)
            bind(deviceID.uuidString, to: $0, at: 3)
            bind(folderID.uuidString, to: $0, at: 4)
            bind(song.url.standardizedFileURL.path, to: $0, at: 5)
            bind(volumeIdentifier(for: song.url), to: $0, at: 6)
            bind(song.fileSizeBytes, to: $0, at: 7)
            bind(
                song.fileFingerprint?.modificationDate.timeIntervalSince1970,
                to: $0,
                at: 8
            )
            bind(scanToken, to: $0, at: 9)
            sqlite3_bind_double($0, 10, Date().timeIntervalSince1970)
        }
    }

    private func isHidden(trackID: UUID) throws -> Bool {
        let statement = try prepare(
            """
            SELECT hidden OR deleted_at IS NOT NULL
            FROM track_state
            WHERE track_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_int(statement, 0) != 0
    }

    private func isFavourite(trackID: UUID) throws -> Bool {
        let statement = try prepare(
            """
            SELECT favourite
            FROM track_state
            WHERE track_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_int(statement, 0) != 0
    }

    /// Background-identification genre/mood tags for `trackID`, re-read from
    /// `track_state` on every rescan (like `isFavourite` above) rather than carried over
    /// from the incoming scanned `Song`, since `AudioScanner` never populates them — they
    /// only ever come from `applyIdentification`.
    private func moodAndGenreTags(
        trackID: UUID
    ) throws -> (genres: [String], moods: [String]) {
        let statement = try prepare(
            """
            SELECT mb_genres_json, mood_tags_json
            FROM track_state
            WHERE track_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return ([], [])
        }
        return (
            stringArray(from: text(statement, 0)),
            stringArray(from: text(statement, 1))
        )
    }

    private func volumeIdentifier(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString
    }

    private func registerLocalDevice() throws {
        try run(
            """
            INSERT INTO devices (id, name, last_seen_at)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                last_seen_at = excluded.last_seen_at
            """
        ) {
            bind(deviceID.uuidString, to: $0, at: 1)
            bind(Host.current().localizedName ?? "Mac", to: $0, at: 2)
            sqlite3_bind_double($0, 3, Date().timeIntervalSince1970)
        }
    }

    private func appendChange(
        entityType: String,
        entityID: String,
        operation: String,
        payload: String
    ) throws {
        let clock = Int64(Date().timeIntervalSince1970 * 1_000)
        try run(
            """
            INSERT INTO changes
                (operation_id, device_id, entity_type, entity_id, operation,
                 payload, logical_clock, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) {
            bind(UUID().uuidString, to: $0, at: 1)
            bind(deviceID.uuidString, to: $0, at: 2)
            bind(entityType, to: $0, at: 3)
            bind(entityID, to: $0, at: 4)
            bind(operation, to: $0, at: 5)
            bind(payload, to: $0, at: 6)
            sqlite3_bind_int64($0, 7, clock)
            sqlite3_bind_double($0, 8, Date().timeIntervalSince1970)
        }
    }

    private func appendOutboxOperation(
        entityType: String,
        entityID: String,
        operation: String,
        payload: JSONValue,
        now: TimeInterval
    ) throws {
        let payloadData = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw LibraryDatabaseError.unavailable
        }
        try run(
            """
            INSERT INTO sync_outbox
                (operation_id, device_id, entity_type, entity_id, operation,
                 payload, physical_millis, logical_counter, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
            """
        ) {
            bind(UUID().uuidString, to: $0, at: 1)
            bind(deviceID.uuidString, to: $0, at: 2)
            bind(entityType, to: $0, at: 3)
            bind(entityID, to: $0, at: 4)
            bind(operation, to: $0, at: 5)
            bind(payloadText, to: $0, at: 6)
            sqlite3_bind_int64($0, 7, Int64(now * 1_000))
            sqlite3_bind_double($0, 8, now)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(
        _ sql: String,
        bindings: (OpaquePointer) -> Void = { _ in }
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let connection else {
            throw LibraryDatabaseError.unavailable
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
            == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let connection else {
            throw LibraryDatabaseError.unavailable
        }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func databaseError() -> Error {
        guard let connection,
              let message = sqlite3_errmsg(connection) else {
            return LibraryDatabaseError.unavailable
        }
        return LibraryDatabaseError.sqlite(String(cString: message))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        return Data(
            bytes: bytes,
            count: Int(sqlite3_column_bytes(statement, column))
        )
    }

    private func optionalDouble(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, column)
    }

    private func optionalInt(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, column))
    }

    private func optionalInt64(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, column)
    }

    /// Decodes a `track_state.mb_genres_json`/`mood_tags_json`-style column (a
    /// JSON-array-encoded string, or `NULL`) into `[String]`. Malformed or missing JSON
    /// just yields no tags rather than failing the whole song read.
    private func stringArray(from json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func bind(
        _ value: String?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
    }

    private func bind(
        _ value: Data?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(
                statement,
                index,
                $0.baseAddress,
                Int32($0.count),
                Self.transient
            )
        }
    }

    private func bind(
        _ value: Double?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(
        _ value: Int?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(
        _ value: Int64?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Aro", isDirectory: true)
            .appendingPathComponent("Library Data", isDirectory: true)
            .appendingPathComponent("Aro.sqlite3")
    }

    static func legacyDefaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Aro", isDirectory: true)
            .appendingPathComponent("Aro.sqlite3")
    }

    static func prepareDefaultStore() {
        copyStoreIfNeeded(from: legacyDefaultURL(), to: defaultURL())
    }

    static func copyStoreIfNeeded(from source: URL, to destination: URL) {
        let files = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
              files.fileExists(atPath: source.path),
              !files.fileExists(atPath: destination.path) else {
            return
        }
        do {
            try files.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try files.copyItem(at: source, to: destination)
            for suffix in ["-wal", "-shm"] {
                let sourceSidecar = URL(fileURLWithPath: source.path + suffix)
                let destinationSidecar = URL(
                    fileURLWithPath: destination.path + suffix
                )
                if files.fileExists(atPath: sourceSidecar.path) {
                    try files.copyItem(
                        at: sourceSidecar,
                        to: destinationSidecar
                    )
                }
            }
        } catch {
            // The original database remains untouched and will be retried on
            // the next launch.
        }
    }
}

enum LibraryDatabaseError: LocalizedError {
    case unavailable
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Aro library database is unavailable."
        case .sqlite(let message):
            return "The Aro library database failed: \(message)"
        }
    }
}
