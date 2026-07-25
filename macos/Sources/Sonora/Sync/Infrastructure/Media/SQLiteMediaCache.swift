import Foundation
import Observation
import SQLite3
import SonoraCommon

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
    var statusMessage: String?
    var errorMessage: String?

    init(database: LibraryDatabase) {
        cache = SQLiteMediaCache(database: database)
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
        } catch {
            errorMessage = error.localizedDescription
        }
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
