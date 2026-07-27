import Foundation
import Observation
import SQLite3
import AroCommon

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
        guard policy != .stream else { return [] }
        return database.withReadConnection { connection in
            var statement: OpaquePointer?
            let predicate: String
            var albums: [String] = []
            switch policy {
            case .stream:
                return []
            case .favourites:
                predicate = "AND s.favourite = 1"
            case .selectedAlbums(let selected):
                albums = selected.sorted()
                guard !albums.isEmpty else { return [] }
                predicate = "AND m.album IN (\(albums.map { _ in "?" }.joined(separator: ",")))"
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
                ORDER BY t.id
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
}

struct CachingSHA256MediaVerifier: MediaHashVerifying {
    let cache: SQLiteMediaCache
    private let verifier = SHA256MediaVerifier()

    func verify(file: URL, expectedSHA256: String) async throws {
        try await verifier.verify(
            file: file,
            expectedSHA256: expectedSHA256
        )
        let byteCount = try file.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        cache.register(
            hash: expectedSHA256,
            localURL: file,
            byteCount: Int64(byteCount)
        )
    }
}

@MainActor
@Observable
final class MediaCacheController {
    private let cache: SQLiteMediaCache
    private let prepare: PrepareSongForPlayback?
    var statusMessage: String?
    var errorMessage: String?
    private(set) var downloadProgress: (completed: Int, total: Int)?
    private(set) var usedBytes: Int64 = 0
    private(set) var downloadedFileCount = 0
    private(set) var protectedFileCount = 0

    init(
        database: LibraryDatabase,
        prepare: PrepareSongForPlayback? = nil
    ) {
        cache = SQLiteMediaCache(database: database)
        self.prepare = prepare
        refreshSummary()
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

    func apply(_ policy: OfflineDownloadPolicy) async {
        let media = cache.media(for: policy)
        cache.replacePins(with: Set(media.map(\.contentHash)))
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
