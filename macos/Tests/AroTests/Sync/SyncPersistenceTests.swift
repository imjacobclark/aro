#if canImport(XCTest)
import Foundation
import SQLite3
import AroCommon
import XCTest
@testable import Aro

final class SyncPersistenceTests: XCTestCase {
    func testMembershipPresenceDistinguishesFreshClients() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let store = SQLiteSyncOperationStore(database: database)
        XCTAssertFalse(store.hasMemberships)
        XCTAssertTrue(store.activeWatchedFolderPaths.isEmpty)

        database.save(
            folder: WatchedFolder(
                id: UUID(),
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        XCTAssertEqual(store.activeWatchedFolderPaths, [directory.path])

        store.upsertMembership(
            hub: AroHubInfo(
                hubID: UUID(),
                displayName: "Fresh Hub",
                protocolMin: 2,
                protocolMax: 2,
                pairingAvailable: true
            ),
            baseURL: URL(string: "https://aro.local:4848")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            replicaMode: .onDemand
        )

        XCTAssertTrue(store.hasMemberships)
    }

    func testCacheEvictionProtectsPinnedQueuedAndPlayingFiles() {
        let now = Date()
        let entries = [
            CachedBlob(
                contentHash: "old",
                byteCount: 10,
                lastAccessedAt: now.addingTimeInterval(-100)
            ),
            CachedBlob(
                contentHash: "pin",
                byteCount: 10,
                lastAccessedAt: now.addingTimeInterval(-200),
                isPinned: true
            ),
            CachedBlob(
                contentHash: "queue",
                byteCount: 10,
                lastAccessedAt: now.addingTimeInterval(-300),
                isQueued: true
            ),
            CachedBlob(
                contentHash: "current",
                byteCount: 10,
                lastAccessedAt: now.addingTimeInterval(-400),
                isCurrent: true
            ),
            CachedBlob(
                contentHash: "new",
                byteCount: 10,
                lastAccessedAt: now
            ),
        ]

        XCTAssertEqual(
            CacheEvictionPolicy().evictionCandidates(
                entries: entries,
                limitBytes: 35
            ).map(\.contentHash),
            ["old", "new"]
        )
    }

    func testRemoteOperationIsAppliedOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let store = SQLiteSyncOperationStore(database: database)
        let operationID = UUID()
        let hubID = UUID()

        XCTAssertTrue(
            store.beginRemoteApply(
                operationID: operationID,
                hubID: hubID,
                sequence: 1
            )
        )
        XCTAssertFalse(
            store.beginRemoteApply(
                operationID: operationID,
                hubID: hubID,
                sequence: 1
            )
        )
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testRemoteTrackStateAppliesWithoutCreatingOutboxEcho() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let local = try XCTUnwrap(
            database.reconcile(
                songs: [
                    Song(
                        url: directory.appendingPathComponent("Track.flac"),
                        title: "Track",
                        artist: "Artist",
                        duration: 1,
                        fileFingerprint: AudioFileFingerprint(
                            standardizedPath: "/Track.flac",
                            fileSizeBytes: 1,
                            modificationDate: Date(),
                            contentHash: "hash"
                        )
                    )
                ],
                folderID: folderID
            ).first
        )
        let hubID = UUID()
        let hubTrackID = UUID()
        database.withConnection { connection in
            let sql = """
            INSERT INTO hub_memberships
                (hub_id, display_name, base_url, tls_fingerprint, joined_at)
            VALUES ('\(hubID)', 'Hub', 'https://hub', 'fingerprint', 0);
            INSERT INTO hub_track_mappings
                (hub_id, local_track_id, hub_track_id)
            VALUES ('\(hubID)', '\(local.libraryID)', '\(hubTrackID)');
            """
            sqlite3_exec(connection, sql, nil, nil, nil)
        }
        let operationID = UUID()
        let remoteDeviceID = UUID()
        let operation = SequencedSyncOperation(
            sequence: 1,
            operationID: operationID,
            deviceID: remoteDeviceID,
            entityType: "track_state",
            entityID: hubTrackID.uuidString,
            kind: "update",
            payload: .object(["favourite": .bool(true)]),
            fieldVersions: [
                "favourite": SyncFieldVersion(
                    physicalMilliseconds: 2_000,
                    logical: 0,
                    deviceID: remoteDeviceID
                ),
            ]
        )
        let store = SQLiteSyncOperationStore(database: database)
        XCTAssertTrue(
            try store.applyRemote(operation, hubID: hubID)
        )
        XCTAssertFalse(
            try store.applyRemote(operation, hubID: hubID)
        )
        XCTAssertTrue(store.pending().isEmpty)
        let stale = SequencedSyncOperation(
            sequence: 2,
            operationID: UUID(),
            deviceID: UUID(),
            entityType: "track_state",
            entityID: hubTrackID.uuidString,
            kind: "update",
            payload: .object(["favourite": .bool(false)]),
            fieldVersions: [
                "favourite": SyncFieldVersion(
                    physicalMilliseconds: 1_000,
                    logical: 0,
                    deviceID: UUID()
                ),
            ]
        )
        XCTAssertTrue(try store.applyRemote(stale, hubID: hubID))

        let favourite = database.withReadConnection { connection in
            var statement: OpaquePointer?
            sqlite3_prepare_v2(
                connection,
                "SELECT favourite FROM track_state WHERE track_id = ?",
                -1,
                &statement,
                nil
            )
            defer { sqlite3_finalize(statement) }
            _ = local.libraryID.uuidString.withCString {
                sqlite3_bind_text(
                    statement,
                    1,
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            return sqlite3_step(statement) == SQLITE_ROW
                && sqlite3_column_int(statement, 0) == 1
        }
        XCTAssertEqual(favourite, true)
    }

    func testFirstJoinManifestKeepsLocalIDsAndExistingHubMappings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let song = try XCTUnwrap(
            database.reconcile(
                songs: [
                    Song(
                        url: directory.appendingPathComponent("Track.flac"),
                        title: "Track",
                        artist: "Artist",
                        duration: 90,
                        fileFingerprint: AudioFileFingerprint(
                            standardizedPath: "/Track.flac",
                            fileSizeBytes: 12,
                            modificationDate: Date(),
                            contentHash: "content-hash"
                        )
                    )
                ],
                folderID: folderID
            ).first
        )
        let hubID = UUID()
        let hubTrackID = UUID()
        let store = SQLiteSyncOperationStore(database: database)
        let hubURL = URL(string: "https://hub.local:4848")!
        store.upsertMembership(
            hub: AroHubInfo(
                hubID: hubID,
                displayName: "Living Room",
                protocolMin: 2,
                protocolMax: 2,
                pairingAvailable: false
            ),
            baseURL: hubURL,
            tlsFingerprint: String(repeating: "a", count: 64),
            replicaMode: .onDemand
        )
        let membership = try XCTUnwrap(store.membership(baseURL: hubURL))
        XCTAssertEqual(membership.hubID, hubID)
        XCTAssertEqual(
            membership.tlsFingerprint,
            String(repeating: "a", count: 64)
        )
        database.withConnection { connection in
            sqlite3_exec(
                connection,
                """
                INSERT INTO hub_track_mappings
                    (hub_id, local_track_id, hub_track_id)
                VALUES ('\(hubID)', '\(song.libraryID)', '\(hubTrackID)')
                """,
                nil,
                nil,
                nil
            )
        }

        let manifest = store.manifest(hubID: hubID)
        XCTAssertEqual(manifest.count, 1)
        XCTAssertEqual(manifest[0].localTrackID, song.libraryID.uuidString)
        XCTAssertEqual(manifest[0].hubTrackID, hubTrackID)
        XCTAssertEqual(manifest[0].contentHash, "content-hash")
        XCTAssertEqual(
            manifest[0].fields["title"]?.value,
            .string("Track")
        )
    }

    func testRemoteTrackCreatesReplicaAndMappingWithoutOutboxEcho() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let store = SQLiteSyncOperationStore(database: database)
        let hubID = UUID()
        store.upsertMembership(
            hub: AroHubInfo(
                hubID: hubID,
                displayName: "Hub",
                protocolMin: 2,
                protocolMax: 2,
                pairingAvailable: false
            ),
            baseURL: URL(string: "https://hub.local:4848")!,
            tlsFingerprint: String(repeating: "b", count: 64),
            replicaMode: .onDemand
        )
        let hubTrackID = UUID()
        let remote = SequencedSyncOperation(
            sequence: 4,
            operationID: UUID(),
            deviceID: UUID(),
            entityType: "track",
            entityID: hubTrackID.uuidString,
            kind: "upsert",
            payload: .object([
                "content_hash": .string("remote-hash"),
                "byte_count": .number(1_024),
                "title": .string("Remote Track"),
                "artist": .string("Remote Artist"),
            ]),
            fieldVersions: [:]
        )

        XCTAssertTrue(try store.applyRemote(remote, hubID: hubID))
        XCTAssertFalse(try store.applyRemote(remote, hubID: hubID))
        XCTAssertTrue(store.pending().isEmpty)
        let manifest = store.manifest(hubID: hubID)
        XCTAssertEqual(manifest.count, 1)
        let entry = try XCTUnwrap(manifest.first)
        XCTAssertEqual(entry.hubTrackID, hubTrackID)
        XCTAssertEqual(entry.contentHash, "remote-hash")
        XCTAssertEqual(
            entry.fields["artist"]?.value,
            .string("Remote Artist")
        )
    }
}
#endif
