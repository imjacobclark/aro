import Foundation
import SQLite3
import AroCommon

struct StoredHubMembership: Sendable {
    let hubID: UUID
    let tlsFingerprint: String
}

struct StoredHubMembershipSummary: Sendable {
    let hubID: UUID
    let displayName: String
    let baseURL: URL
    let tlsFingerprint: String
    let replicaMode: SyncReplicaMode
    let joinedAt: Date
}

struct StoredSyncStatus: Sendable {
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let lastError: String?
    let uploadedOperations: Int
    let appliedOperations: Int
}

struct StoredSyncActivity: Identifiable, Sendable {
    let id: UUID
    let kind: String
    let message: String
    let state: String
    let createdAt: Date
}

struct StoredMusicContribution: Sendable {
    let fileURL: URL
    let contentHash: String
    let byteCount: UInt64
    let operation: SyncOperation
}

struct PendingSyncOperation: Equatable, Sendable {
    let id: UUID
    let deviceID: UUID
    let entityType: String
    let entityID: String
    let operation: String
    let payload: String
    let physicalMilliseconds: Int64
    let logicalCounter: UInt32

    func wireOperation(
        entityID: String? = nil,
        payload overridePayload: JSONValue? = nil
    ) throws -> SyncOperation {
        let data = Data(payload.utf8)
        let value: JSONValue
        if let overridePayload {
            value = overridePayload
        } else {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        let fields: [String]
        if case .object(let object) = value {
            fields = Array(object.keys)
        } else {
            fields = []
        }
        let version = SyncFieldVersion(
            physicalMilliseconds: physicalMilliseconds,
            logical: logicalCounter,
            deviceID: deviceID
        )
        return SyncOperation(
            operationID: id,
            deviceID: deviceID,
            entityType: entityType,
            entityID: entityID ?? self.entityID,
            kind: operation,
            payload: value,
            fieldVersions: Dictionary(
                uniqueKeysWithValues: fields.map { ($0, version) }
            )
        )
    }
}

struct SQLiteSyncOperationStore {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
        repairRemoteLibraryFolders()
    }

    /// Older clients accidentally converted remote library URLs into `/` when
    /// saving their synthetic watched-folder row. Repair those rows before the
    /// library store restores them, otherwise it scans the Mac's filesystem
    /// root instead of displaying the already-synchronized remote catalogue.
    private func repairRemoteLibraryFolders() {
        database.withConnection { connection in
            _ = sqlite3_exec(
                connection,
                """
                UPDATE watched_folders
                SET path = (
                    SELECT base_url
                    FROM hub_memberships
                    WHERE hub_memberships.hub_id = watched_folders.id
                )
                WHERE EXISTS (
                    SELECT 1
                    FROM hub_memberships
                    WHERE hub_memberships.hub_id = watched_folders.id
                      AND watched_folders.path != hub_memberships.base_url
                )
                """,
                nil,
                nil,
                nil
            )
            _ = sqlite3_exec(
                connection,
                """
                UPDATE file_locations
                SET available = 1,
                    updated_at = strftime('%s', 'now')
                WHERE folder_id IN (
                    SELECT hub_id FROM hub_memberships
                )
                  AND (
                    path LIKE 'https://%'
                    OR path LIKE 'http://%'
                  )
                """,
                nil,
                nil,
                nil
            )
        }
    }

    func pending(limit: Int = 200) -> [PendingSyncOperation] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT operation_id, device_id, entity_type, entity_id,
                       operation, payload, physical_millis, logical_counter
                FROM sync_outbox
                WHERE sent_at IS NULL
                ORDER BY created_at, operation_id
                LIMIT ?
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 1_000))))

            var operations: [PendingSyncOperation] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let id = text(statement, 0).flatMap(UUID.init(uuidString:)),
                  let deviceID = text(statement, 1).flatMap(UUID.init(uuidString:)),
                  let entityType = text(statement, 2),
                  let entityID = text(statement, 3),
                  let operation = text(statement, 4),
                  let payload = text(statement, 5) {
                operations.append(
                    PendingSyncOperation(
                        id: id,
                        deviceID: deviceID,
                        entityType: entityType,
                        entityID: entityID,
                        operation: operation,
                        payload: payload,
                        physicalMilliseconds: sqlite3_column_int64(
                            statement,
                            6
                        ),
                        logicalCounter: UInt32(
                            sqlite3_column_int64(statement, 7)
                        )
                    )
                )
            }
            return operations
        } ?? []
    }

    func markSent(_ operationIDs: [UUID]) {
        guard !operationIDs.isEmpty else { return }
        database.withConnection { connection in
            for operationID in operationIDs {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(
                    connection,
                    """
                    UPDATE sync_outbox
                    SET sent_at = ?
                    WHERE operation_id = ? AND sent_at IS NULL
                    """,
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK,
                      let statement else {
                    continue
                }
                sqlite3_bind_double(
                    statement,
                    1,
                    Date().timeIntervalSince1970
                )
                bind(operationID.uuidString, statement, 2)
                _ = sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
        }
    }

    func serverCursor(hubID: UUID) -> UInt64 {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                "SELECT server_cursor FROM hub_memberships WHERE hub_id = ?",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return 0
            }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)
            return sqlite3_step(statement) == SQLITE_ROW
                ? UInt64(sqlite3_column_int64(statement, 0))
                : 0
        } ?? 0
    }

    func upsertMembership(
        hub: AroHubInfo,
        baseURL: URL,
        tlsFingerprint: String,
        replicaMode: SyncReplicaMode
    ) {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                INSERT INTO hub_memberships
                    (hub_id, display_name, base_url, tls_fingerprint,
                     replica_mode, server_cursor, joined_at)
                VALUES (?, ?, ?, ?, ?, 0, ?)
                ON CONFLICT(hub_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    base_url = excluded.base_url,
                    tls_fingerprint = excluded.tls_fingerprint,
                    replica_mode = excluded.replica_mode
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(hub.hubID.uuidString, statement, 1)
            bind(hub.displayName, statement, 2)
            bind(baseURL.absoluteString, statement, 3)
            bind(tlsFingerprint.lowercased(), statement, 4)
            bind(replicaMode.rawValue, statement, 5)
            sqlite3_bind_double(
                statement,
                6,
                Date().timeIntervalSince1970
            )
            _ = sqlite3_step(statement)
            ensureRemoteLibraryFolder(
                hub: hub,
                baseURL: baseURL,
                connection: connection
            )
        }
    }

    func membership(baseURL: URL) -> StoredHubMembership? {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT hub_id, tls_fingerprint
                FROM hub_memberships
                WHERE base_url = ?
                ORDER BY joined_at DESC
                LIMIT 1
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            bind(baseURL.absoluteString, statement, 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let hubIDText = sqlite3_column_text(statement, 0),
                  let fingerprintText = sqlite3_column_text(statement, 1),
                  let hubID = UUID(
                      uuidString: String(cString: hubIDText)
                  ) else {
                return nil
            }
            return StoredHubMembership(
                hubID: hubID,
                tlsFingerprint: String(cString: fingerprintText)
            )
        } ?? nil
    }

    var hasMemberships: Bool {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                "SELECT 1 FROM hub_memberships LIMIT 1",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        } ?? false
    }

    var membershipSummaries: [StoredHubMembershipSummary] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT hub_id, display_name, base_url, tls_fingerprint,
                       replica_mode, joined_at
                FROM hub_memberships
                ORDER BY joined_at
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            var memberships: [StoredHubMembershipSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let hubID = text(statement, 0).flatMap(
                    UUID.init(uuidString:)
                  ),
                  let displayName = text(statement, 1),
                  let baseURLText = text(statement, 2),
                  let baseURL = URL(string: baseURLText) {
                memberships.append(
                    StoredHubMembershipSummary(
                        hubID: hubID,
                        displayName: displayName,
                        baseURL: baseURL,
                        tlsFingerprint: text(statement, 3) ?? "",
                        replicaMode: text(statement, 4)
                            .flatMap(SyncReplicaMode.init(rawValue:))
                            ?? .onDemand,
                        joinedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                5
                            )
                        )
                    )
                )
            }
            return memberships
        } ?? []
    }

    var activeWatchedFolderPaths: [String] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT path
                FROM watched_folders
                WHERE removed_at IS NULL
                ORDER BY path
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            var paths: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let path = text(statement, 0) {
                paths.append(path)
            }
            return paths
        } ?? []
    }

    func sourceHealthReports(mode: String) -> [SourceHealthReport] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT id, display_name, path
                FROM watched_folders
                WHERE removed_at IS NULL
                ORDER BY display_name
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            var reports: [SourceHealthReport] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let sourceID = text(statement, 0).flatMap(
                    UUID.init(uuidString:)
                  ),
                  let name = text(statement, 1),
                  let path = text(statement, 2) {
                var isDirectory: ObjCBool = false
                let available = FileManager.default.fileExists(
                    atPath: path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
                reports.append(
                    SourceHealthReport(
                        sourceID: sourceID,
                        name: name,
                        mode: mode,
                        available: available,
                        warning: available
                            ? nil
                            : (
                                mode == "managed"
                                    ? "The original folder is unavailable. Aro’s stored copy remains available."
                                    : "This linked folder is unavailable. Its songs cannot be served until the folder is online."
                            )
                    )
                )
            }
            return reports
        } ?? []
    }

    func musicContributions(hubID: UUID) -> [StoredMusicContribution] {
        let entries = Dictionary(
            uniqueKeysWithValues: manifest(hubID: hubID).map {
                ($0.localTrackID, $0)
            }
        )
        return database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT tracks.id, tracks.content_hash, file_locations.path,
                       COALESCE(file_locations.file_size, 0),
                       file_locations.folder_id
                FROM tracks
                JOIN file_locations ON file_locations.track_id = tracks.id
                LEFT JOIN hub_track_mappings
                    ON hub_track_mappings.local_track_id = tracks.id
                   AND hub_track_mappings.hub_id = ?
                LEFT JOIN track_state ON track_state.track_id = tracks.id
                WHERE hub_track_mappings.hub_track_id IS NULL
                  AND tracks.content_hash IS NOT NULL
                  AND file_locations.available = 1
                  AND track_state.deleted_at IS NULL
                GROUP BY tracks.id
                ORDER BY tracks.id
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)
            var values: [StoredMusicContribution] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let localTrackID = text(statement, 0),
                  let entityID = UUID(uuidString: localTrackID),
                  let hash = text(statement, 1),
                  let path = text(statement, 2),
                  let entry = entries[localTrackID] {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.isReadableFile(atPath: path) else {
                    continue
                }
                let actualSize = (try? url.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize).map(UInt64.init)
                    ?? UInt64(max(0, sqlite3_column_int64(statement, 3)))
                var payload = Dictionary(
                    uniqueKeysWithValues: entry.fields.map {
                        ($0.key, $0.value.value)
                    }
                )
                payload["content_hash"] = .string(hash)
                payload["byte_count"] = .number(Double(actualSize))
                payload["original_filename"] = .string(
                    url.lastPathComponent
                )
                payload["original_extension"] = .string(
                    url.pathExtension.lowercased()
                )
                if let sourceID = text(statement, 4) {
                    payload["source_id"] = .string(sourceID)
                }
                let version = entry.fields.values.first?.timestamp
                    ?? SyncFieldVersion(
                        physicalMilliseconds: Int64(
                            Date().timeIntervalSince1970 * 1_000
                        ),
                        logical: 0,
                        deviceID: database.deviceID
                    )
                values.append(
                    StoredMusicContribution(
                        fileURL: url,
                        contentHash: hash,
                        byteCount: actualSize,
                        operation: SyncOperation(
                            operationID: entityID,
                            deviceID: database.deviceID,
                            entityType: "track",
                            entityID: entityID.uuidString,
                            kind: "upsert",
                            payload: .object(payload),
                            fieldVersions: Dictionary(
                                uniqueKeysWithValues: payload.keys.map {
                                    ($0, version)
                                }
                            )
                        )
                    )
                )
            }
            return values
        } ?? []
    }

    func recordSyncStarted(hubID: UUID) {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                INSERT INTO sync_status
                    (hub_id, last_attempt_at, last_error)
                VALUES (?, ?, NULL)
                ON CONFLICT(hub_id) DO UPDATE SET
                    last_attempt_at = excluded.last_attempt_at,
                    last_error = NULL
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            _ = sqlite3_step(statement)
        }
    }

    func recordSyncSucceeded(
        hubID: UUID,
        result: SyncRunResult
    ) {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                INSERT INTO sync_status
                    (hub_id, last_attempt_at, last_success_at, last_error,
                     uploaded_operations, applied_operations)
                VALUES (?, ?, ?, NULL, ?, ?)
                ON CONFLICT(hub_id) DO UPDATE SET
                    last_attempt_at = excluded.last_attempt_at,
                    last_success_at = excluded.last_success_at,
                    last_error = NULL,
                    uploaded_operations = excluded.uploaded_operations,
                    applied_operations = excluded.applied_operations
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            bind(hubID.uuidString, statement, 1)
            sqlite3_bind_double(statement, 2, now)
            sqlite3_bind_double(statement, 3, now)
            sqlite3_bind_int(statement, 4, Int32(result.uploadedOperations))
            sqlite3_bind_int(statement, 5, Int32(result.appliedOperations))
            _ = sqlite3_step(statement)
            appendActivity(
                hubID: hubID,
                kind: "sync",
                message: result.appliedOperations == 0
                    ? "Library is up to date"
                    : "Updated \(result.appliedOperations) library items",
                state: "success",
                connection: connection
            )
        }
    }

    func recordSyncFailed(hubID: UUID, message: String) {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                INSERT INTO sync_status
                    (hub_id, last_attempt_at, last_error)
                VALUES (?, ?, ?)
                ON CONFLICT(hub_id) DO UPDATE SET
                    last_attempt_at = excluded.last_attempt_at,
                    last_error = excluded.last_error
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            bind(message, statement, 3)
            _ = sqlite3_step(statement)
            appendActivity(
                hubID: hubID,
                kind: "sync",
                message: message,
                state: "error",
                connection: connection
            )
        }
    }

    func syncStatus(hubID: UUID) -> StoredSyncStatus? {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT last_attempt_at, last_success_at, last_error,
                       uploaded_operations, applied_operations
                FROM sync_status WHERE hub_id = ?
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredSyncStatus(
                lastAttemptAt: optionalDate(statement, column: 0),
                lastSuccessAt: optionalDate(statement, column: 1),
                lastError: text(statement, 2),
                uploadedOperations: Int(sqlite3_column_int(statement, 3)),
                appliedOperations: Int(sqlite3_column_int(statement, 4))
            )
        } ?? nil
    }

    func recentActivity(hubID: UUID?, limit: Int = 5) -> [StoredSyncActivity] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = hubID == nil
                ? """
                  SELECT id, kind, message, state, created_at
                  FROM sync_activity
                  ORDER BY created_at DESC LIMIT ?
                  """
                : """
                  SELECT id, kind, message, state, created_at
                  FROM sync_activity
                  WHERE hub_id = ?
                  ORDER BY created_at DESC LIMIT ?
                  """
            guard sqlite3_prepare_v2(
                connection,
                sql,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let hubID {
                bind(hubID.uuidString, statement, index)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(max(1, min(limit, 50))))
            var activity: [StoredSyncActivity] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let id = text(statement, 0).flatMap(UUID.init(uuidString:)),
                  let kind = text(statement, 1),
                  let message = text(statement, 2),
                  let state = text(statement, 3) {
                activity.append(
                    StoredSyncActivity(
                        id: id,
                        kind: kind,
                        message: message,
                        state: state,
                        createdAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                4
                            )
                        )
                    )
                )
            }
            return activity
        } ?? []
    }

    func manifest(hubID: UUID) -> [SyncManifestEntry] {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT tracks.id, tracks.content_hash, tracks.updated_at,
                       scan_metadata.title, scan_metadata.artist,
                       scan_metadata.duration, scan_metadata.codec,
                       scan_metadata.sample_rate, scan_metadata.bit_depth,
                       scan_metadata.channel_count, scan_metadata.bitrate,
                       scan_metadata.album, scan_metadata.genre,
                       scan_metadata.release_year,
                       track_state.hidden, track_state.favourite,
                       track_state.rating, track_state.title_override,
                       track_state.artist_override, track_state.deleted_at,
                       track_state.updated_at,
                       hub_track_mappings.hub_track_id
                FROM tracks
                LEFT JOIN scan_metadata
                    ON scan_metadata.track_id = tracks.id
                LEFT JOIN track_state
                    ON track_state.track_id = tracks.id
                LEFT JOIN hub_track_mappings
                    ON hub_track_mappings.local_track_id = tracks.id
                   AND hub_track_mappings.hub_id = ?
                ORDER BY tracks.id
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)

            var entries: [SyncManifestEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let localTrackID = text(statement, 0) {
                let updatedAt = max(
                    sqlite3_column_double(statement, 2),
                    sqlite3_column_type(statement, 20) == SQLITE_NULL
                        ? 0
                        : sqlite3_column_double(statement, 20)
                )
                let version = SyncFieldVersion(
                    physicalMilliseconds: Int64(updatedAt * 1_000),
                    logical: 0,
                    deviceID: database.deviceID
                )
                var fields: [String: VersionedJSONValue] = [:]
                addTextField(
                    "title",
                    column: 3,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addTextField(
                    "artist",
                    column: 4,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addNumberField(
                    "duration",
                    column: 5,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addTextField(
                    "codec",
                    column: 6,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addNumberField(
                    "sample_rate",
                    column: 7,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addIntegerField(
                    "bit_depth",
                    column: 8,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addIntegerField(
                    "channel_count",
                    column: 9,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addNumberField(
                    "bitrate",
                    column: 10,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addTextField(
                    "album",
                    column: 11,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addTextField(
                    "genre",
                    column: 12,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addIntegerField(
                    "release_year",
                    column: 13,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addBooleanField(
                    "hidden",
                    column: 14,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addBooleanField(
                    "favourite",
                    column: 15,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addIntegerField(
                    "rating",
                    column: 16,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addTextField(
                    "title_override",
                    column: 17,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                addTextField(
                    "artist_override",
                    column: 18,
                    statement: statement,
                    version: version,
                    fields: &fields
                )
                entries.append(
                    SyncManifestEntry(
                        localTrackID: localTrackID,
                        hubTrackID: text(statement, 21)
                            .flatMap(UUID.init(uuidString:)),
                        contentHash: text(statement, 1),
                        fields: fields,
                        tombstoned: sqlite3_column_type(statement, 19)
                            != SQLITE_NULL
                    )
                )
            }
            return entries
        } ?? []
    }

    func hubTrackID(localTrackID: String, hubID: UUID) -> String? {
        database.withReadConnection { connection in
            self.localHubTrackID(
                localTrackID: localTrackID,
                hubID: hubID,
                connection: connection
            )
        } ?? nil
    }

    func updateCursor(hubID: UUID, sequence: UInt64) {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                UPDATE hub_memberships
                SET server_cursor = MAX(server_cursor, ?)
                WHERE hub_id = ?
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(sequence))
            bind(hubID.uuidString, statement, 2)
            _ = sqlite3_step(statement)
        }
    }

    func applyRemote(
        _ sequenced: SequencedSyncOperation,
        hubID: UUID
    ) throws -> Bool {
        let result: Result<Bool, Error>? = database.withConnection {
            connection in
            do {
                try execute("BEGIN IMMEDIATE", connection)
                try run(
                    """
                    INSERT OR IGNORE INTO applied_sync_operations
                        (operation_id, hub_id, server_sequence, applied_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    connection
                ) {
                    bind(sequenced.operationID.uuidString, $0, 1)
                    bind(hubID.uuidString, $0, 2)
                    sqlite3_bind_int64($0, 3, Int64(sequenced.sequence))
                    sqlite3_bind_double(
                        $0,
                        4,
                        Date().timeIntervalSince1970
                    )
                }
                guard sqlite3_changes(connection) == 1 else {
                    try execute("COMMIT", connection)
                    return .success(false)
                }

                let mergedPayload = mergeablePayload(
                    sequenced,
                    hubID: hubID,
                    connection: connection
                )
                if sequenced.entityType == "track" {
                    try applyTrack(
                        sequenced,
                        payload: mergedPayload,
                        hubID: hubID,
                        connection: connection
                    )
                } else if sequenced.entityType == "track_state",
                   let localTrackID = localTrackID(
                    hubTrackID: sequenced.entityID,
                    hubID: hubID,
                    connection: connection
                   ) {
                    try applyTrackState(
                        sequenced,
                        payload: mergedPayload,
                        localTrackID: localTrackID,
                        connection: connection
                    )
                } else if sequenced.entityType == "listening_session" {
                    try applyListeningSession(
                        sequenced,
                        hubID: hubID,
                        connection: connection
                    )
                } else if sequenced.entityType == "loudness" {
                    try applyLoudness(
                        sequenced,
                        connection: connection
                    )
                }
                for (field, version) in sequenced.fieldVersions {
                    try run(
                        """
                        INSERT INTO sync_field_versions
                            (hub_id, entity_type, entity_id, field_name,
                             physical_millis, logical_counter, device_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hub_id, entity_type, entity_id, field_name)
                        DO UPDATE SET
                            physical_millis = excluded.physical_millis,
                            logical_counter = excluded.logical_counter,
                            device_id = excluded.device_id
                        WHERE excluded.physical_millis > physical_millis
                           OR (
                                excluded.physical_millis = physical_millis
                                AND excluded.logical_counter > logical_counter
                           )
                           OR (
                                excluded.physical_millis = physical_millis
                                AND excluded.logical_counter = logical_counter
                                AND excluded.device_id > device_id
                           )
                        """,
                        connection
                    ) {
                        bind(hubID.uuidString, $0, 1)
                        bind(sequenced.entityType, $0, 2)
                        bind(sequenced.entityID, $0, 3)
                        bind(field, $0, 4)
                        sqlite3_bind_int64(
                            $0,
                            5,
                            version.physicalMilliseconds
                        )
                        sqlite3_bind_int64($0, 6, Int64(version.logical))
                        bind(version.deviceID.uuidString, $0, 7)
                    }
                }
                try run(
                    """
                    UPDATE hub_memberships
                    SET server_cursor = MAX(server_cursor, ?)
                    WHERE hub_id = ?
                    """,
                    connection
                ) {
                    sqlite3_bind_int64($0, 1, Int64(sequenced.sequence))
                    bind(hubID.uuidString, $0, 2)
                }
                try execute("COMMIT", connection)
                return .success(true)
            } catch {
                try? execute("ROLLBACK", connection)
                return .failure(error)
            }
        }
        guard let result else {
            throw LibraryDatabaseError.unavailable
        }
        return try result.get()
    }

    /// Creates this Mac's `local_hub_membership` row the first time it replicates
    /// from its own local hub, if one doesn't already exist (idempotent: never
    /// resets `server_cursor` on a hub already known), and a matching
    /// `watched_folders` row so replicated songs have somewhere to group under
    /// in the existing folder-scoped song list -- the same trick
    /// `ensureRemoteLibraryFolder` uses for a remote hub's synced content, with
    /// `id = hub_id` again standing in for "this isn't really a folder."
    func ensureLocalHubMembership(hubID: UUID, displayName: String) {
        database.withConnection { connection in
            try? run(
                """
                INSERT OR IGNORE INTO local_hub_membership
                    (hub_id, server_cursor, joined_at)
                VALUES (?, 0, ?)
                """,
                connection
            ) {
                bind(hubID.uuidString, $0, 1)
                sqlite3_bind_double($0, 2, Date().timeIntervalSince1970)
            }
            try? run(
                """
                INSERT INTO watched_folders
                    (id, display_name, path, bookmark, added_at, removed_at)
                VALUES (?, ?, ?, NULL, ?, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    removed_at = NULL
                """,
                connection
            ) {
                bind(hubID.uuidString, $0, 1)
                bind(displayName, $0, 2)
                bind("aro-local-hub://\(hubID.uuidString)", $0, 3)
                sqlite3_bind_double($0, 4, Date().timeIntervalSince1970)
            }
        }
    }

    func localHubServerCursor(hubID: UUID) -> UInt64 {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                "SELECT server_cursor FROM local_hub_membership WHERE hub_id = ?",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return 0
            }
            defer { sqlite3_finalize(statement) }
            bind(hubID.uuidString, statement, 1)
            return sqlite3_step(statement) == SQLITE_ROW
                ? UInt64(sqlite3_column_int64(statement, 0))
                : 0
        } ?? 0
    }

    /// Applies one operation pulled from this Mac's own local hub over the
    /// control socket (`HubControlClient.changesAfter`), mirroring
    /// `applyRemote`'s per-operation CRDT merge but against
    /// `local_hub_membership`/`local_hub_track_mappings` rather than
    /// `hub_memberships`/`hub_track_mappings` — see those tables' comments in
    /// `SQLiteSchemaMigrator` for why a same-machine hub needs its own, simpler
    /// membership concept instead of reusing the remote-hub-shaped ones.
    ///
    /// `localPath`, when the operation is a `track` with a resolvable content
    /// hash, should already have been resolved via
    /// `HubControlClient.trackLocation(hash:)` by the caller — a control-socket
    /// round trip can't happen inside this synchronous SQLite transaction.
    /// `track_state`/`loudness` reuse the exact same private apply helpers
    /// `applyRemote` uses; only track application and hub-track-id lookup
    /// differ, because `applyTrack` writes an HTTPS blob URL into
    /// `file_locations` (correct for a genuinely remote hub's streamed/cached
    /// content) where this needs a real on-disk path instead.
    @discardableResult
    func applyLocalHub(
        _ sequenced: SequencedSyncOperation,
        hubID: UUID,
        localPath: String?
    ) throws -> Bool {
        let result: Result<Bool, Error>? = database.withConnection {
            connection in
            do {
                try execute("BEGIN IMMEDIATE", connection)
                try run(
                    """
                    INSERT OR IGNORE INTO applied_sync_operations
                        (operation_id, hub_id, server_sequence, applied_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    connection
                ) {
                    bind(sequenced.operationID.uuidString, $0, 1)
                    bind(hubID.uuidString, $0, 2)
                    sqlite3_bind_int64($0, 3, Int64(sequenced.sequence))
                    sqlite3_bind_double(
                        $0,
                        4,
                        Date().timeIntervalSince1970
                    )
                }
                guard sqlite3_changes(connection) == 1 else {
                    try execute("COMMIT", connection)
                    return .success(false)
                }

                let mergedPayload = mergeablePayload(
                    sequenced,
                    hubID: hubID,
                    connection: connection
                )
                if sequenced.entityType == "track" {
                    try applyLocalHubTrack(
                        sequenced,
                        payload: mergedPayload,
                        hubID: hubID,
                        localPath: localPath,
                        connection: connection
                    )
                } else if sequenced.entityType == "track_state",
                   let localTrackID = localTrackIDForLocalHub(
                    hubTrackID: sequenced.entityID,
                    hubID: hubID,
                    connection: connection
                   ) {
                    try applyTrackState(
                        sequenced,
                        payload: mergedPayload,
                        localTrackID: localTrackID,
                        connection: connection
                    )
                } else if sequenced.entityType == "loudness" {
                    try applyLoudness(
                        sequenced,
                        connection: connection
                    )
                }
                // "listening_session" is deliberately not handled: this Mac's own
                // local hub never originates that entity type (its operation log
                // only ever contains what SourceManager scans, plus whatever this
                // Mac itself pushes -- and this pull-only coordinator never
                // pushes), so it would never actually appear here. Listening
                // history stays purely local, recorded directly by
                // SQLiteListeningHistoryRecorder.
                for (field, version) in sequenced.fieldVersions {
                    try run(
                        """
                        INSERT INTO sync_field_versions
                            (hub_id, entity_type, entity_id, field_name,
                             physical_millis, logical_counter, device_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hub_id, entity_type, entity_id, field_name)
                        DO UPDATE SET
                            physical_millis = excluded.physical_millis,
                            logical_counter = excluded.logical_counter,
                            device_id = excluded.device_id
                        WHERE excluded.physical_millis > physical_millis
                           OR (
                                excluded.physical_millis = physical_millis
                                AND excluded.logical_counter > logical_counter
                           )
                           OR (
                                excluded.physical_millis = physical_millis
                                AND excluded.logical_counter = logical_counter
                                AND excluded.device_id > device_id
                           )
                        """,
                        connection
                    ) {
                        bind(hubID.uuidString, $0, 1)
                        bind(sequenced.entityType, $0, 2)
                        bind(sequenced.entityID, $0, 3)
                        bind(field, $0, 4)
                        sqlite3_bind_int64(
                            $0,
                            5,
                            version.physicalMilliseconds
                        )
                        sqlite3_bind_int64($0, 6, Int64(version.logical))
                        bind(version.deviceID.uuidString, $0, 7)
                    }
                }
                try run(
                    """
                    UPDATE local_hub_membership
                    SET server_cursor = MAX(server_cursor, ?)
                    WHERE hub_id = ?
                    """,
                    connection
                ) {
                    sqlite3_bind_int64($0, 1, Int64(sequenced.sequence))
                    bind(hubID.uuidString, $0, 2)
                }
                try execute("COMMIT", connection)
                return .success(true)
            } catch {
                try? execute("ROLLBACK", connection)
                return .failure(error)
            }
        }
        guard let result else {
            throw LibraryDatabaseError.unavailable
        }
        return try result.get()
    }

    private func localTrackIDForLocalHub(
        hubTrackID: String,
        hubID: UUID,
        connection: OpaquePointer
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            """
            SELECT local_track_id FROM local_hub_track_mappings
            WHERE hub_id = ? AND hub_track_id = ?
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(hubID.uuidString, statement, 1)
        bind(hubTrackID, statement, 2)
        return sqlite3_step(statement) == SQLITE_ROW
            ? text(statement, 0)
            : nil
    }

    /// Same shape as `applyTrack`, but for a same-machine hub: `file_locations`
    /// gets a real filesystem path (already resolved by the caller via
    /// `HubControlClient.trackLocation(hash:)`) instead of an HTTPS blob URL.
    /// `folder_id` still points at the synthetic `watched_folders` row
    /// `ensureLocalHubMembership` creates (`id = hub_id`), same trick
    /// `ensureRemoteLibraryFolder` uses for a remote hub -- without it, synced
    /// songs would have no folder to group under in `LibraryStore.folders` and
    /// would never appear in the song list.
    private func applyLocalHubTrack(
        _ sequenced: SequencedSyncOperation,
        payload: [String: JSONValue],
        hubID: UUID,
        localPath: String?,
        connection: OpaquePointer
    ) throws {
        guard UUID(uuidString: sequenced.entityID) != nil,
              case .object = sequenced.payload else { return }
        let contentHash = string(payload["content_hash"])
        let localTrackID = localTrackIDForLocalHub(
            hubTrackID: sequenced.entityID,
            hubID: hubID,
            connection: connection
        ) ?? contentHash.flatMap {
            trackID(
                contentHash: $0,
                connection: connection
            )
        } ?? UUID().uuidString
        let now = Date().timeIntervalSince1970

        try run(
            """
            INSERT INTO tracks (id, content_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content_hash = COALESCE(excluded.content_hash, content_hash),
                updated_at = excluded.updated_at
            """,
            connection
        ) {
            bind(localTrackID, $0, 1)
            bindOptional(contentHash, $0, 2)
            sqlite3_bind_double($0, 3, now)
            sqlite3_bind_double($0, 4, now)
        }
        try run(
            """
            INSERT INTO local_hub_track_mappings
                (hub_id, local_track_id, hub_track_id)
            VALUES (?, ?, ?)
            ON CONFLICT(hub_id, local_track_id) DO UPDATE SET
                hub_track_id = excluded.hub_track_id
            """,
            connection
        ) {
            bind(hubID.uuidString, $0, 1)
            bind(localTrackID, $0, 2)
            bind(sequenced.entityID, $0, 3)
        }
        try run(
            """
            INSERT INTO scan_metadata
                (track_id, title, artist, duration, codec, sample_rate,
                 bit_depth, channel_count, bitrate, scanned_at, album, genre,
                 release_year, artwork_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                title = COALESCE(excluded.title, title),
                artist = COALESCE(excluded.artist, artist),
                duration = COALESCE(excluded.duration, duration),
                codec = COALESCE(excluded.codec, codec),
                sample_rate = COALESCE(excluded.sample_rate, sample_rate),
                bit_depth = COALESCE(excluded.bit_depth, bit_depth),
                channel_count = COALESCE(
                    excluded.channel_count,
                    channel_count
                ),
                bitrate = COALESCE(excluded.bitrate, bitrate),
                scanned_at = excluded.scanned_at,
                album = COALESCE(excluded.album, album),
                genre = COALESCE(excluded.genre, genre),
                release_year = COALESCE(
                    excluded.release_year,
                    release_year
                ),
                artwork_url = COALESCE(excluded.artwork_url, artwork_url)
            """,
            connection
        ) {
            bind(localTrackID, $0, 1)
            bindOptional(string(payload["title"]), $0, 2)
            bindOptional(string(payload["artist"]), $0, 3)
            bindOptional(number(payload["duration"]), $0, 4)
            bindOptional(string(payload["codec"]), $0, 5)
            bindOptional(number(payload["sample_rate"]), $0, 6)
            bindOptional(integer(payload["bit_depth"]), $0, 7)
            bindOptional(integer(payload["channel_count"]), $0, 8)
            bindOptional(number(payload["bitrate"]), $0, 9)
            sqlite3_bind_double($0, 10, now)
            bindOptional(string(payload["album"]), $0, 11)
            bindOptional(string(payload["genre"]), $0, 12)
            bindOptional(integer(payload["release_year"]), $0, 13)
            bindOptional(string(payload["artwork_url"]), $0, 14)
        }
        try run(
            """
            INSERT OR IGNORE INTO track_state (track_id, updated_at)
            VALUES (?, ?)
            """,
            connection
        ) {
            bind(localTrackID, $0, 1)
            sqlite3_bind_double($0, 2, now)
        }
        try applyTrackState(
            sequenced,
            payload: payload,
            localTrackID: localTrackID,
            connection: connection
        )
        if let contentHash,
           let byteCount = integer(payload["byte_count"]) {
            try run(
                """
                INSERT INTO blob_availability
                    (content_hash, local_path, byte_count, verified, pinned,
                     download_state)
                VALUES (?, ?, ?, 1, 0, 'available')
                ON CONFLICT(content_hash) DO UPDATE SET
                    local_path = COALESCE(excluded.local_path, local_path),
                    byte_count = excluded.byte_count,
                    verified = 1,
                    download_state = 'available'
                """,
                connection
            ) {
                bind(contentHash, $0, 1)
                bindOptional(localPath, $0, 2)
                sqlite3_bind_int64($0, 3, byteCount)
            }
            if let localPath {
                try run(
                    """
                    INSERT INTO file_locations
                        (id, track_id, device_id, folder_id, path, file_size,
                         available, last_seen_token, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        track_id = excluded.track_id,
                        folder_id = excluded.folder_id,
                        path = excluded.path,
                        file_size = excluded.file_size,
                        available = 1,
                        last_seen_token = excluded.last_seen_token,
                        updated_at = excluded.updated_at
                    """,
                    connection
                ) {
                    bind(
                        "\(hubID.uuidString):\(sequenced.entityID)",
                        $0,
                        1
                    )
                    bind(localTrackID, $0, 2)
                    bind(database.deviceID.uuidString, $0, 3)
                    bind(hubID.uuidString, $0, 4)
                    bind(localPath, $0, 5)
                    sqlite3_bind_int64($0, 6, byteCount)
                    bind("local-hub-\(sequenced.sequence)", $0, 7)
                    sqlite3_bind_double($0, 8, now)
                }
            }
        }
    }

    /// Records the remote operation before its mutation is applied. Retrying a
    /// page therefore cannot create a local outbox echo or apply twice.
    func beginRemoteApply(
        operationID: UUID,
        hubID: UUID,
        sequence: Int64
    ) -> Bool {
        database.withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                INSERT OR IGNORE INTO applied_sync_operations
                    (operation_id, hub_id, server_sequence, applied_at)
                VALUES (?, ?, ?, ?)
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            bind(operationID.uuidString, statement, 1)
            bind(hubID.uuidString, statement, 2)
            sqlite3_bind_int64(statement, 3, sequence)
            sqlite3_bind_double(
                statement,
                4,
                Date().timeIntervalSince1970
            )
            return sqlite3_step(statement) == SQLITE_DONE
                && sqlite3_changes(connection) == 1
        } ?? false
    }

    private func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        sqlite3_column_text(statement, column).map(String.init(cString:))
    }

    private func optionalDate(
        _ statement: OpaquePointer,
        column: Int32
    ) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(
            timeIntervalSince1970: sqlite3_column_double(statement, column)
        )
    }

    private func appendActivity(
        hubID: UUID?,
        kind: String,
        message: String,
        state: String,
        connection: OpaquePointer
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            """
            INSERT INTO sync_activity
                (id, hub_id, kind, message, state, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else { return }
        bind(UUID().uuidString, statement, 1)
        if let hubID {
            bind(hubID.uuidString, statement, 2)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        bind(kind, statement, 3)
        bind(message, statement, 4)
        bind(state, statement, 5)
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
        _ = sqlite3_exec(
            connection,
            """
            DELETE FROM sync_activity
            WHERE id NOT IN (
                SELECT id FROM sync_activity
                ORDER BY created_at DESC LIMIT 200
            )
            """,
            nil,
            nil,
            nil
        )
    }

    private func addTextField(
        _ name: String,
        column: Int32,
        statement: OpaquePointer,
        version: SyncFieldVersion,
        fields: inout [String: VersionedJSONValue]
    ) {
        guard let value = text(statement, column) else { return }
        fields[name] = VersionedJSONValue(
            value: .string(value),
            timestamp: version
        )
    }

    private func addNumberField(
        _ name: String,
        column: Int32,
        statement: OpaquePointer,
        version: SyncFieldVersion,
        fields: inout [String: VersionedJSONValue]
    ) {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return
        }
        fields[name] = VersionedJSONValue(
            value: .number(sqlite3_column_double(statement, column)),
            timestamp: version
        )
    }

    private func addIntegerField(
        _ name: String,
        column: Int32,
        statement: OpaquePointer,
        version: SyncFieldVersion,
        fields: inout [String: VersionedJSONValue]
    ) {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return
        }
        fields[name] = VersionedJSONValue(
            value: .number(Double(sqlite3_column_int64(statement, column))),
            timestamp: version
        )
    }

    private func addBooleanField(
        _ name: String,
        column: Int32,
        statement: OpaquePointer,
        version: SyncFieldVersion,
        fields: inout [String: VersionedJSONValue]
    ) {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return
        }
        fields[name] = VersionedJSONValue(
            value: .bool(sqlite3_column_int(statement, column) != 0),
            timestamp: version
        )
    }

    private func localTrackID(
        hubTrackID: String,
        hubID: UUID,
        connection: OpaquePointer
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            """
            SELECT local_track_id FROM hub_track_mappings
            WHERE hub_id = ? AND hub_track_id = ?
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(hubID.uuidString, statement, 1)
        bind(hubTrackID, statement, 2)
        return sqlite3_step(statement) == SQLITE_ROW
            ? text(statement, 0)
            : nil
    }

    private func localHubTrackID(
        localTrackID: String,
        hubID: UUID,
        connection: OpaquePointer
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            """
            SELECT hub_track_id FROM hub_track_mappings
            WHERE hub_id = ? AND local_track_id = ?
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(hubID.uuidString, statement, 1)
        bind(localTrackID, statement, 2)
        return sqlite3_step(statement) == SQLITE_ROW
            ? text(statement, 0)
            : nil
    }

    private func applyTrack(
        _ sequenced: SequencedSyncOperation,
        payload: [String: JSONValue],
        hubID: UUID,
        connection: OpaquePointer
    ) throws {
        guard UUID(uuidString: sequenced.entityID) != nil,
              case .object = sequenced.payload else { return }
        let contentHash = string(payload["content_hash"])
        let localTrackID = localTrackID(
            hubTrackID: sequenced.entityID,
            hubID: hubID,
            connection: connection
        ) ?? contentHash.flatMap {
            trackID(
                contentHash: $0,
                connection: connection
            )
        } ?? UUID().uuidString
        let now = Date().timeIntervalSince1970

        try run(
            """
            INSERT INTO tracks (id, content_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content_hash = COALESCE(excluded.content_hash, content_hash),
                updated_at = excluded.updated_at
            """,
            connection
        ) {
            bind(localTrackID, $0, 1)
            bindOptional(contentHash, $0, 2)
            sqlite3_bind_double($0, 3, now)
            sqlite3_bind_double($0, 4, now)
        }
        try run(
            """
            INSERT INTO hub_track_mappings
                (hub_id, local_track_id, hub_track_id)
            VALUES (?, ?, ?)
            ON CONFLICT(hub_id, local_track_id) DO UPDATE SET
                hub_track_id = excluded.hub_track_id
            """,
            connection
        ) {
            bind(hubID.uuidString, $0, 1)
            bind(localTrackID, $0, 2)
            bind(sequenced.entityID, $0, 3)
        }
        try run(
            """
            INSERT INTO scan_metadata
                (track_id, title, artist, duration, codec, sample_rate,
                 bit_depth, channel_count, bitrate, scanned_at, album, genre,
                 release_year, artwork_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                title = COALESCE(excluded.title, title),
                artist = COALESCE(excluded.artist, artist),
                duration = COALESCE(excluded.duration, duration),
                codec = COALESCE(excluded.codec, codec),
                sample_rate = COALESCE(excluded.sample_rate, sample_rate),
                bit_depth = COALESCE(excluded.bit_depth, bit_depth),
                channel_count = COALESCE(
                    excluded.channel_count,
                    channel_count
                ),
                bitrate = COALESCE(excluded.bitrate, bitrate),
                scanned_at = excluded.scanned_at,
                album = COALESCE(excluded.album, album),
                genre = COALESCE(excluded.genre, genre),
                release_year = COALESCE(
                    excluded.release_year,
                    release_year
                ),
                artwork_url = COALESCE(excluded.artwork_url, artwork_url)
            """,
            connection
        ) {
            bind(localTrackID, $0, 1)
            bindOptional(string(payload["title"]), $0, 2)
            bindOptional(string(payload["artist"]), $0, 3)
            bindOptional(number(payload["duration"]), $0, 4)
            bindOptional(string(payload["codec"]), $0, 5)
            bindOptional(number(payload["sample_rate"]), $0, 6)
            bindOptional(integer(payload["bit_depth"]), $0, 7)
            bindOptional(integer(payload["channel_count"]), $0, 8)
            bindOptional(number(payload["bitrate"]), $0, 9)
            sqlite3_bind_double($0, 10, now)
            bindOptional(string(payload["album"]), $0, 11)
            bindOptional(string(payload["genre"]), $0, 12)
            bindOptional(integer(payload["release_year"]), $0, 13)
            bindOptional(string(payload["artwork_url"]), $0, 14)
        }
        try run(
            """
            INSERT OR IGNORE INTO track_state (track_id, updated_at)
            VALUES (?, ?)
            """,
            connection
        ) {
            bind(localTrackID, $0, 1)
            sqlite3_bind_double($0, 2, now)
        }
        try applyTrackState(
            sequenced,
            payload: payload,
            localTrackID: localTrackID,
            connection: connection
        )
        if let contentHash,
           let byteCount = integer(payload["byte_count"]) {
            try run(
                """
                INSERT INTO blob_availability
                    (content_hash, byte_count, verified, pinned,
                     download_state)
                VALUES (?, ?, 0, 0, 'absent')
                ON CONFLICT(content_hash) DO UPDATE SET
                    byte_count = excluded.byte_count
                """,
                connection
            ) {
                bind(contentHash, $0, 1)
                sqlite3_bind_int64($0, 2, byteCount)
            }
            if let baseURL = membershipBaseURL(
                hubID: hubID,
                connection: connection
            ) {
                let mediaURL = baseURL
                    .appendingPathComponent("v1/blobs")
                    .appendingPathComponent(contentHash)
                try run(
                    """
                    INSERT INTO file_locations
                        (id, track_id, device_id, folder_id, path, file_size,
                         available, last_seen_token, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        track_id = excluded.track_id,
                        folder_id = excluded.folder_id,
                        path = excluded.path,
                        file_size = excluded.file_size,
                        available = 1,
                        last_seen_token = excluded.last_seen_token,
                        updated_at = excluded.updated_at
                    """,
                    connection
                ) {
                    bind(
                        "\(hubID.uuidString):\(sequenced.entityID)",
                        $0,
                        1
                    )
                    bind(localTrackID, $0, 2)
                    bind(database.deviceID.uuidString, $0, 3)
                    bind(hubID.uuidString, $0, 4)
                    bind(mediaURL.absoluteString, $0, 5)
                    sqlite3_bind_int64($0, 6, byteCount)
                    bind("remote-\(sequenced.sequence)", $0, 7)
                    sqlite3_bind_double($0, 8, now)
                }
            }
        }
    }

    private func ensureRemoteLibraryFolder(
        hub: AroHubInfo,
        baseURL: URL,
        connection: OpaquePointer
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            """
            INSERT INTO watched_folders
                (id, display_name, path, bookmark, added_at, removed_at)
            VALUES (?, ?, ?, NULL, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                path = excluded.path,
                removed_at = NULL
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(hub.hubID.uuidString, statement, 1)
        bind(hub.displayName, statement, 2)
        bind(baseURL.absoluteString, statement, 3)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        _ = sqlite3_step(statement)
    }

    private func membershipBaseURL(
        hubID: UUID,
        connection: OpaquePointer
    ) -> URL? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "SELECT base_url FROM hub_memberships WHERE hub_id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(hubID.uuidString, statement, 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = text(statement, 0) else {
            return nil
        }
        return URL(string: value)
    }

    private func trackID(
        contentHash: String,
        connection: OpaquePointer
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "SELECT id FROM tracks WHERE content_hash = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(contentHash, statement, 1)
        return sqlite3_step(statement) == SQLITE_ROW
            ? text(statement, 0)
            : nil
    }

    private func applyTrackState(
        _ sequenced: SequencedSyncOperation,
        payload: [String: JSONValue],
        localTrackID: String,
        connection: OpaquePointer
    ) throws {
        guard case .object = sequenced.payload else { return }
        let hidden = payload["hidden"].flatMap {
            if case .bool(let value) = $0 { value } else { nil }
        }
        let favourite = payload["favourite"].flatMap {
            if case .bool(let value) = $0 { value } else { nil }
        }
        let rating = payload["rating"].flatMap {
            if case .number(let value) = $0 { Int(value) } else { nil }
        }
        let titleOverride = string(payload["title_override"])
        let artistOverride = string(payload["artist_override"])
        let now = Date().timeIntervalSince1970
        try run(
            """
            UPDATE track_state
            SET hidden = COALESCE(?, hidden),
                favourite = COALESCE(?, favourite),
                rating = COALESCE(?, rating),
                title_override = COALESCE(?, title_override),
                artist_override = COALESCE(?, artist_override),
                deleted_at = CASE
                    WHEN ? = 'delete' OR ? = 'tombstone' THEN ?
                    WHEN ? = 'restore' THEN NULL
                    ELSE deleted_at
                END,
                updated_at = ?
            WHERE track_id = ?
            """,
            connection
        ) {
            if let hidden {
                sqlite3_bind_int($0, 1, hidden ? 1 : 0)
            } else {
                sqlite3_bind_null($0, 1)
            }
            if let favourite {
                sqlite3_bind_int($0, 2, favourite ? 1 : 0)
            } else {
                sqlite3_bind_null($0, 2)
            }
            if let rating {
                sqlite3_bind_int($0, 3, Int32(rating))
            } else {
                sqlite3_bind_null($0, 3)
            }
            bindOptional(titleOverride, $0, 4)
            bindOptional(artistOverride, $0, 5)
            bind(sequenced.kind, $0, 6)
            bind(sequenced.kind, $0, 7)
            sqlite3_bind_double($0, 8, now)
            bind(sequenced.kind, $0, 9)
            sqlite3_bind_double($0, 10, now)
            bind(localTrackID, $0, 11)
        }
    }

    private func applyListeningSession(
        _ sequenced: SequencedSyncOperation,
        hubID: UUID,
        connection: OpaquePointer
    ) throws {
        guard case .object(let payload) = sequenced.payload,
              case .string(let hubTrackID)? = payload["track_id"],
              let localTrackID = localTrackID(
                hubTrackID: hubTrackID,
                hubID: hubID,
                connection: connection
              ),
              case .number(let startedAt)? = payload["started_at"],
              case .number(let endedAt)? = payload["ended_at"],
              case .number(let listenedSeconds)? = payload["listened_seconds"],
              case .bool(let completed)? = payload["completed"] else {
            return
        }
        try run(
            """
            INSERT OR IGNORE INTO listening_sessions
                (id, track_id, device_id, started_at, last_heartbeat_at,
                 ended_at, listened_seconds, completed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            connection
        ) {
            bind(sequenced.entityID, $0, 1)
            bind(localTrackID, $0, 2)
            bind(sequenced.deviceID.uuidString, $0, 3)
            sqlite3_bind_double($0, 4, startedAt)
            sqlite3_bind_double($0, 5, endedAt)
            sqlite3_bind_double($0, 6, endedAt)
            sqlite3_bind_double($0, 7, listenedSeconds)
            sqlite3_bind_int($0, 8, completed ? 1 : 0)
        }
    }

    private func applyLoudness(
        _ sequenced: SequencedSyncOperation,
        connection: OpaquePointer
    ) throws {
        guard case .object(let payload) = sequenced.payload,
              case .string(let hash)? = payload["content_hash"],
              case .number(let version)? = payload["algorithm_version"],
              case .number(let lufs)? = payload["integrated_lufs"],
              case .number(let peak)? = payload["peak_amplitude"],
              case .number(let analyzedAt)? = payload["analyzed_at"] else {
            return
        }
        try run(
            """
            INSERT INTO loudness_analysis
                (fingerprint, algorithm_version, integrated_lufs,
                 peak_amplitude, analyzed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(fingerprint, algorithm_version) DO UPDATE SET
                integrated_lufs = excluded.integrated_lufs,
                peak_amplitude = excluded.peak_amplitude,
                analyzed_at = excluded.analyzed_at
            """,
            connection
        ) {
            bind(hash, $0, 1)
            sqlite3_bind_int($0, 2, Int32(version))
            sqlite3_bind_double($0, 3, lufs)
            sqlite3_bind_double($0, 4, peak)
            sqlite3_bind_double($0, 5, analyzedAt)
        }
    }

    private func mergeablePayload(
        _ operation: SequencedSyncOperation,
        hubID: UUID,
        connection: OpaquePointer
    ) -> [String: JSONValue] {
        guard case .object(let payload) = operation.payload,
              operation.entityType == "track"
                || operation.entityType == "track_state" else {
            if case .object(let payload) = operation.payload {
                return payload
            }
            return [:]
        }
        return payload.filter { field, _ in
            guard let remote = operation.fieldVersions[field] else {
                return true
            }
            return shouldApply(
                remote,
                hubID: hubID,
                entityType: operation.entityType,
                entityID: operation.entityID,
                field: field,
                connection: connection
            )
        }
    }

    private func shouldApply(
        _ remote: SyncFieldVersion,
        hubID: UUID,
        entityType: String,
        entityID: String,
        field: String,
        connection: OpaquePointer
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            """
            SELECT physical_millis, logical_counter, device_id
            FROM sync_field_versions
            WHERE hub_id = ? AND entity_type = ?
              AND entity_id = ? AND field_name = ?
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(hubID.uuidString, statement, 1)
        bind(entityType, statement, 2)
        bind(entityID, statement, 3)
        bind(field, statement, 4)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let deviceID = text(statement, 2).flatMap(UUID.init(uuidString:))
        else {
            return true
        }
        let local = SyncFieldVersion(
            physicalMilliseconds: sqlite3_column_int64(statement, 0),
            logical: UInt32(sqlite3_column_int64(statement, 1)),
            deviceID: deviceID
        )
        return local < remote
    }

    private func run(
        _ sql: String,
        _ connection: OpaquePointer,
        bindings: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw sqliteError(connection)
        }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(connection)
        }
    }

    private func execute(
        _ sql: String,
        _ connection: OpaquePointer
    ) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(connection)
        }
    }

    /// `LibraryDatabaseError.unavailable` means "no connection at all" — using it
    /// for every SQL failure (constraint violations, malformed statements, busy
    /// locks) was actively misleading: it told users their whole database was
    /// unreachable when the connection was fine and one specific statement had
    /// failed for a real, diagnosable reason. Surfacing `sqlite3_errmsg` instead
    /// keeps that reason visible instead of discarding it.
    private func sqliteError(_ connection: OpaquePointer) -> Error {
        guard let message = sqlite3_errmsg(connection) else {
            return LibraryDatabaseError.unavailable
        }
        return LibraryDatabaseError.sqlite(String(cString: message))
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

    private func bindOptional(
        _ value: String?,
        _ statement: OpaquePointer,
        _ index: Int32
    ) {
        if let value {
            bind(value, statement, index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptional(
        _ value: Double?,
        _ statement: OpaquePointer,
        _ index: Int32
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptional(
        _ value: Int64?,
        _ statement: OpaquePointer,
        _ index: Int32
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptional(
        _ value: Bool?,
        _ statement: OpaquePointer,
        _ index: Int32
    ) {
        if let value {
            sqlite3_bind_int(statement, index, value ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func number(_ value: JSONValue?) -> Double? {
        guard case .number(let value) = value else { return nil }
        return value
    }

    private func integer(_ value: JSONValue?) -> Int64? {
        number(value).map(Int64.init)
    }

    private func boolean(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }
}
