import Foundation
import Observation
import SQLite3
import AroCommon

final class MediaStoragePolicyState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPolicy: OfflineDownloadPolicy

    init(_ policy: OfflineDownloadPolicy) {
        storedPolicy = policy
    }

    var policy: OfflineDownloadPolicy {
        lock.lock()
        defer { lock.unlock() }
        return storedPolicy
    }

    func update(_ policy: OfflineDownloadPolicy) {
        lock.lock()
        storedPolicy = policy
        lock.unlock()
    }
}

struct SQLiteMediaCache: Sendable {
    let database: LibraryDatabase

    func entries(
        currentHash: String? = nil,
        queuedHashes: Set<String> = []
    ) -> [CachedBlob] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT content_hash, byte_count, last_accessed_at, pinned
                FROM blob_availability
                WHERE local_path IS NOT NULL AND verified = 1
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            var entries: [CachedBlob] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let hash = sqlite3_column_text(statement, 0)
                    .map(String.init(cString:)) {
                entries.append(
                    CachedBlob(
                        contentHash: hash,
                        byteCount: sqlite3_column_int64(statement, 1),
                        lastAccessedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                2
                            )
                        ),
                        isPinned: sqlite3_column_int(statement, 3) != 0,
                        isQueued: queuedHashes.contains(hash),
                        isCurrent: currentHash == hash
                    )
                )
            }
            return entries
        } ?? []
    }

    func removedEntries() -> [CachedBlob] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT DISTINCT b.content_hash, b.byte_count,
                       b.last_accessed_at, b.pinned
                FROM blob_availability AS b
                JOIN tracks AS t ON t.content_hash = b.content_hash
                JOIN track_state AS s ON s.track_id = t.id
                WHERE b.local_path IS NOT NULL
                  AND b.verified = 1
                  AND s.deleted_at IS NOT NULL
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            var entries: [CachedBlob] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let hash = sqlite3_column_text(statement, 0)
                    .map(String.init(cString:)) {
                entries.append(
                    CachedBlob(
                        contentHash: hash,
                        byteCount: sqlite3_column_int64(statement, 1),
                        lastAccessedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                2
                            )
                        ),
                        isPinned: sqlite3_column_int(statement, 3) != 0
                    )
                )
            }
            return entries
        } ?? []
    }

    func register(
        hash: String,
        localURL: URL,
        byteCount: Int64,
        pinned: Bool = false
    ) {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                INSERT INTO blob_availability
                    (content_hash, local_path, byte_count, verified, pinned,
                     last_accessed_at, download_state)
                VALUES (?, ?, ?, 1, ?, ?, 'available')
                ON CONFLICT(content_hash) DO UPDATE SET
                    local_path = excluded.local_path,
                    byte_count = excluded.byte_count,
                    verified = 1,
                    pinned = MAX(pinned, excluded.pinned),
                    last_accessed_at = excluded.last_accessed_at,
                    download_state = 'available'
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(hash, statement, 1)
            bind(localURL.path, statement, 2)
            sqlite3_bind_int64(statement, 3, byteCount)
            sqlite3_bind_int(statement, 4, pinned ? 1 : 0)
            sqlite3_bind_double(
                statement,
                5,
                Date().timeIntervalSince1970
            )
            _ = sqlite3_step(statement)
        }
    }

    func media(for policy: OfflineDownloadPolicy) -> [RemoteMedia] {
        guard policy != .streamOnly, policy != .stream else { return [] }
        return database.withReadConnection { connection in
            var statement: OpaquePointer?
            let predicate: String
            var albums: [String] = []
            switch policy {
            case .streamOnly, .stream:
                return []
            case .favourites:
                predicate = "AND s.favourite = 1"
            case .selectedAlbums(let selected):
                albums = selected.sorted()
                predicate = albums.isEmpty
                    ? "AND s.favourite = 1"
                    : "AND (s.favourite = 1 OR m.album IN (\(albums.map { _ in "?" }.joined(separator: ","))))"
            case .fullLibrary:
                predicate = ""
            }
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT t.id, t.content_hash, l.file_size, l.path
                FROM tracks AS t
                JOIN track_state AS s ON s.track_id = t.id
                JOIN scan_metadata AS m ON m.track_id = t.id
                JOIN file_locations AS l ON l.track_id = t.id
                WHERE t.content_hash IS NOT NULL
                  AND l.available = 1
                  AND l.path LIKE 'https://%'
                  AND s.deleted_at IS NULL
                  \(predicate)
                ORDER BY s.favourite DESC, m.album, t.id
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            for (offset, album) in albums.enumerated() {
                bind(album, statement, Int32(offset + 1))
            }
            var media: [RemoteMedia] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let trackIDText = text(statement, 0),
                  let trackID = UUID(uuidString: trackIDText),
                  let hash = text(statement, 1),
                  let path = text(statement, 3),
                  let url = URL(string: path) {
                media.append(
                    RemoteMedia(
                        trackID: trackID,
                        contentHash: hash,
                        byteCount: sqlite3_column_int64(statement, 2),
                        downloadURL: url
                    )
                )
            }
            return media
        } ?? []
    }

    func shouldRetainStreamedMedia(
        hash: String,
        policy: OfflineDownloadPolicy
    ) -> Bool {
        switch policy {
        case .streamOnly:
            return false
        case .stream, .fullLibrary:
            return true
        case .favourites:
            return matchesRetentionSelection(hash: hash, albums: [])
        case .selectedAlbums(let albums):
            return matchesRetentionSelection(hash: hash, albums: albums)
        }
    }

    func replacePins(with hashes: Set<String>) {
        database.withConnection { connection in
            _ = sqlite3_exec(
                connection,
                "UPDATE blob_availability SET pinned = 0",
                nil,
                nil,
                nil
            )
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                UPDATE blob_availability
                SET pinned = 1
                WHERE content_hash = ?
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            for hash in hashes {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(hash, statement, 1)
                _ = sqlite3_step(statement)
            }
        }
    }

    func localURL(hash: String) -> URL? {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT local_path FROM blob_availability
                WHERE content_hash = ? AND verified = 1
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            bind(hash, statement, 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let path = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return URL(fileURLWithPath: String(cString: path))
        } ?? nil
    }

    func remove(hash: String) throws {
        if let url = localURL(hash: hash) {
            try? FileManager.default.removeItem(at: url)
        }
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                UPDATE blob_availability
                SET local_path = NULL, verified = 0, download_state = 'absent'
                WHERE content_hash = ?
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(hash, statement, 1)
            _ = sqlite3_step(statement)
        }
    }

    private func bind(
        _ value: String,
        _ statement: OpaquePointer,
        _ index: Int32
    ) {
        _ = value.withCString {
            sqlite3_bind_text(
                statement,
                index,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    private func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        sqlite3_column_text(statement, column).map(String.init(cString:))
    }

    private func matchesRetentionSelection(
        hash: String,
        albums: Set<String>
    ) -> Bool {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            let sortedAlbums = albums.sorted()
            let albumPredicate = sortedAlbums.isEmpty
                ? ""
                : "OR m.album IN (\(sortedAlbums.map { _ in "?" }.joined(separator: ",")))"
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT 1
                FROM tracks AS t
                JOIN track_state AS s ON s.track_id = t.id
                JOIN scan_metadata AS m ON m.track_id = t.id
                WHERE t.content_hash = ?
                  AND s.deleted_at IS NULL
                  AND (s.favourite = 1 \(albumPredicate))
                LIMIT 1
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            bind(hash, statement, 1)
            for (offset, album) in sortedAlbums.enumerated() {
                bind(album, statement, Int32(offset + 2))
            }
            return sqlite3_step(statement) == SQLITE_ROW
        } ?? false
    }
}

struct CachingSHA256MediaVerifier: MediaHashVerifying {
    let cache: SQLiteMediaCache
    var shouldCache: @Sendable (_ hash: String) -> Bool = { _ in true }
    private let verifier = SHA256MediaVerifier()

    func verify(file: URL, expectedSHA256: String) async throws {
        try await verifier.verify(
            file: file,
            expectedSHA256: expectedSHA256
        )
        let byteCount = try file.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        if shouldCache(expectedSHA256) {
            cache.register(
                hash: expectedSHA256,
                localURL: file,
                byteCount: Int64(byteCount)
            )
        }
    }
}

@MainActor
@Observable
final class MediaCacheController {
    private let cache: SQLiteMediaCache
    private let prepare: PrepareSongForPlayback?
    private let cacheDirectory: URL
    private let storagePolicyState: MediaStoragePolicyState
    var statusMessage: String?
    var errorMessage: String?
    private(set) var downloadProgress: (completed: Int, total: Int)?
    private(set) var usedBytes: Int64 = 0
    private(set) var downloadedFileCount = 0
    private(set) var protectedFileCount = 0
    /// A UI-facing snapshot. Table rendering must not synchronously execute a
    /// SQLite query once for every catalog row.
    private(set) var cachedContentHashes: Set<String> = []

    init(
        database: LibraryDatabase,
        prepare: PrepareSongForPlayback? = nil,
        cacheDirectory: URL,
        storagePolicyState: MediaStoragePolicyState
    ) {
        cache = SQLiteMediaCache(database: database)
        self.prepare = prepare
        self.cacheDirectory = cacheDirectory
        self.storagePolicyState = storagePolicyState
        if storagePolicyState.policy == .streamOnly {
            removeAllStoredMedia()
            removeProgressiveArtifacts()
        }
        refreshSummary()
    }

    /// Exposes the underlying (Sendable) cache so callers like the library
    /// exporter can resolve already-downloaded bytes locally instead of
    /// requiring a live connection to the library host.
    var blobCache: SQLiteMediaCache {
        cache
    }

    func refreshSummary(
        currentHash: String? = nil,
        queuedHashes: Set<String> = []
    ) {
        let entries = cache.entries(
            currentHash: currentHash,
            queuedHashes: queuedHashes
        )
        usedBytes = entries.reduce(0) { $0 + $1.byteCount }
        downloadedFileCount = entries.count
        cachedContentHashes = Set(entries.map(\.contentHash))
        protectedFileCount = entries.filter {
            $0.isPinned || $0.isQueued || $0.isCurrent
        }.count
    }

    func clear(
        currentHash: String? = nil,
        queuedHashes: Set<String> = []
    ) {
        do {
            let entries = cache.entries(
                currentHash: currentHash,
                queuedHashes: queuedHashes
            )
            let candidates = CacheEvictionPolicy().evictionCandidates(
                entries: entries,
                limitBytes: 0
            )
            for candidate in candidates {
                try cache.remove(hash: candidate.contentHash)
            }
            statusMessage = "Removed \(candidates.count) cached files."
            errorMessage = nil
            refreshSummary(
                currentHash: currentHash,
                queuedHashes: queuedHashes
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteRemovedDownloads() {
        do {
            let entries = cache.removedEntries()
            for entry in entries {
                try cache.remove(hash: entry.contentHash)
            }
            let bytes = entries.reduce(0) { $0 + $1.byteCount }
            statusMessage = entries.isEmpty
                ? "No removed downloads were found."
                : "Deleted \(entries.count) removed downloads and freed "
                    + ByteCountFormatter.string(
                        fromByteCount: bytes,
                        countStyle: .file
                    )
                    + "."
            errorMessage = nil
            refreshSummary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(
        _ policy: OfflineDownloadPolicy,
        storageLimitBytes: Int64? = nil
    ) async {
        storagePolicyState.update(policy)
        if policy == .streamOnly {
            removeAllStoredMedia()
            removeProgressiveArtifacts()
            statusMessage = "Stream only is active. No music is stored."
            refreshSummary()
            return
        }

        let limit = policy == .fullLibrary
            ? nil
            : resolvedLimit(configured: storageLimitBytes)
        let requestedMedia = cache.media(for: policy)
        let media = limit.map {
            mediaWithinLimit(requestedMedia, limitBytes: $0)
        } ?? requestedMedia
        cache.replacePins(with: Set(media.map(\.contentHash)))
        if let limit {
            enforceLimit(limit)
        }
        guard let prepare, !media.isEmpty else {
            refreshSummary()
            return
        }
        downloadProgress = (0, media.count)
        statusMessage = "Downloading offline music…"
        do {
            for (index, item) in media.enumerated() {
                try Task.checkCancellation()
                let url = try await prepare.execute(.remote(item))
                cache.register(
                    hash: item.contentHash,
                    localURL: url,
                    byteCount: item.byteCount,
                    pinned: true
                )
                downloadProgress = (index + 1, media.count)
            }
            statusMessage = "Offline music is up to date."
            errorMessage = nil
        } catch is CancellationError {
            statusMessage = "Offline download paused."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Some offline music could not be downloaded."
        }
        downloadProgress = nil
        if let limit {
            enforceLimit(limit)
        }
        refreshSummary()
    }

    /// Applies an offline policy directly to the server-resolved catalogue. Normal
    /// clients therefore do not need to replay the hub's CRDT history merely to
    /// decide which content-addressed blobs to retain.
    func apply(
        _ policy: OfflineDownloadPolicy,
        catalog: [CatalogTrack],
        baseURL: URL,
        storageLimitBytes: Int64? = nil
    ) async {
        storagePolicyState.update(policy)
        if policy == .streamOnly {
            removeAllStoredMedia()
            removeProgressiveArtifacts()
            statusMessage = "Stream only is active. No music is stored."
            refreshSummary()
            return
        }

        let selected: [CatalogTrack]
        switch policy {
        case .streamOnly, .stream:
            selected = []
        case .favourites:
            selected = catalog.filter { $0.favourite == true }
        case .selectedAlbums(let albums):
            selected = catalog.filter {
                $0.favourite == true || $0.album.map(albums.contains) == true
            }
        case .fullLibrary:
            selected = catalog
        }
        let requested = selected.compactMap { track -> RemoteMedia? in
            guard track.available,
                  let hash = track.contentHash,
                  let byteCount = track.byteCount else { return nil }
            return RemoteMedia(
                trackID: track.trackID,
                contentHash: hash,
                byteCount: Int64(byteCount),
                downloadURL: baseURL.appendingPathComponent("v1/blobs/\(hash)")
            )
        }
        let limit = policy == .fullLibrary
            ? nil
            : resolvedLimit(configured: storageLimitBytes)
        let media = limit.map {
            mediaWithinLimit(requested, limitBytes: $0)
        } ?? requested
        cache.replacePins(with: Set(media.map(\.contentHash)))
        if let limit { enforceLimit(limit) }
        guard let prepare, !media.isEmpty else {
            refreshSummary()
            return
        }
        downloadProgress = (0, media.count)
        statusMessage = "Downloading offline music…"
        do {
            for (index, item) in media.enumerated() {
                try Task.checkCancellation()
                let url = try await prepare.execute(.remote(item))
                cache.register(
                    hash: item.contentHash,
                    localURL: url,
                    byteCount: item.byteCount,
                    pinned: true
                )
                downloadProgress = (index + 1, media.count)
            }
            statusMessage = "Offline music is up to date."
            errorMessage = nil
        } catch is CancellationError {
            statusMessage = "Offline download paused."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Some offline music could not be downloaded."
        }
        downloadProgress = nil
        if let limit { enforceLimit(limit) }
        refreshSummary()
    }

    func enforceLimit(
        _ limitBytes: Int64,
        currentHash: String? = nil,
        queuedHashes: Set<String> = []
    ) {
        do {
            let candidates = CacheEvictionPolicy().evictionCandidates(
                entries: cache.entries(
                    currentHash: currentHash,
                    queuedHashes: queuedHashes
                ),
                limitBytes: limitBytes
            )
            for candidate in candidates {
                try cache.remove(hash: candidate.contentHash)
            }
            errorMessage = nil
            refreshSummary(
                currentHash: currentHash,
                queuedHashes: queuedHashes
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedLimit(configured: Int64?) -> Int64 {
        if let configured {
            return configured
        }
        let available = (try? cacheDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage).flatMap(Int64.init)
            ?? CacheEvictionPolicy.defaultLimitBytes * 10
        return CacheEvictionPolicy.automaticLimitBytes(
            availableCapacity: available
        )
    }

    private func mediaWithinLimit(
        _ media: [RemoteMedia],
        limitBytes: Int64
    ) -> [RemoteMedia] {
        var remaining = max(0, limitBytes)
        var selected: [RemoteMedia] = []
        for item in media where item.byteCount <= remaining {
            selected.append(item)
            remaining -= item.byteCount
        }
        return selected
    }

    private func removeAllStoredMedia() {
        do {
            let entries = cache.entries()
            for entry in entries {
                try cache.remove(hash: entry.contentHash)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        cache.replacePins(with: [])
    }

    private func removeProgressiveArtifacts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where
            file.pathExtension == "partial"
                || file.pathExtension == "ranges" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

actor FullMirrorCoordinator {
    private let prepare: PrepareSongForPlayback
    private let cache: SQLiteMediaCache

    init(
        prepare: PrepareSongForPlayback,
        cache: SQLiteMediaCache
    ) {
        self.prepare = prepare
        self.cache = cache
    }

    func mirror(_ media: [RemoteMedia]) async throws {
        for item in media {
            try Task.checkCancellation()
            let url = try await prepare.execute(.remote(item))
            cache.register(
                hash: item.contentHash,
                localURL: url,
                byteCount: item.byteCount
            )
        }
    }
}
