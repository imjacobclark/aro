#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

@MainActor
final class DevicesRedesignTests: XCTestCase {
    func testAddDeviceUsesRunningLibraryServiceInsteadOfStalePreference() {
        let server = LocalAroServer(
            pid: 42,
            kind: .bundledHelper,
            listener: "*:4848",
            hubID: UUID(),
            displayName: "Test Library",
            dataPath: "/tmp/running-library",
            sequence: nil,
            trackCount: nil,
            blobCount: nil
        )

        XCTAssertEqual(
            LibrarySettingsView.controlDataLocation(
                preferred: "/tmp/stale-preference",
                servers: [server]
            ),
            "/tmp/running-library"
        )
    }

    func testAddDeviceFallsBackToConfiguredLibraryService() {
        XCTAssertEqual(
            LibrarySettingsView.controlDataLocation(
                preferred: "/tmp/configured-library",
                servers: []
            ),
            "/tmp/configured-library"
        )
    }

    func testPairingInvitationParsesVersionedPayloadAndRejectsExpiry() {
        let expiry = Date.now.addingTimeInterval(300)
        var components = URLComponents()
        components.scheme = "aro"
        components.host = "pair"
        components.queryItems = [
            .init(name: "v", value: "1"),
            .init(name: "hub", value: UUID().uuidString),
            .init(
                name: "address",
                value: "https://aro-example.local:4848"
            ),
            .init(name: "code", value: "123456"),
            .init(
                name: "expires",
                value: String(Int(expiry.timeIntervalSince1970))
            ),
        ]

        let payload = PairingInvitationPayload(url: components.url!)
        XCTAssertEqual(payload?.code, "123456")
        XCTAssertEqual(
            payload?.address.absoluteString,
            "https://aro-example.local:4848"
        )
        XCTAssertNil(
            PairingInvitationPayload(
                url: components.url!,
                now: expiry.addingTimeInterval(1)
            )
        )
    }

    func testProfileRegistryKeepsOneActiveProfileAndPreservesOthers() {
        let suite = "DevicesRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LibraryProfileRegistry(defaults: defaults)
        let local = registry.createLocal(
            name: "Local Library",
            managedMusicPath: "/tmp/local",
            sharingEnabled: true
        )
        let remote = registry.createRemote(
            name: "Remote Library",
            hubID: UUID(),
            baseURL: URL(string: "https://aro.local:4848")!,
            policy: .stream
        )

        XCTAssertEqual(registry.activeProfileID, remote.id)
        XCTAssertEqual(registry.profiles.count, 2)
        XCTAssertEqual(
            local.databasePath,
            LibraryDatabase.defaultURL().path
        )
        XCTAssertTrue(
            local.databasePath.hasSuffix(
                "Application Support/Aro/Library Data/Aro.sqlite3"
            )
        )
        registry.activate(local.id)
        XCTAssertEqual(registry.activeProfileID, local.id)
        XCTAssertNotNil(registry.profiles.first { $0.id == remote.id })
    }

    func testRemovingActiveProfileReassignsActiveIDToLocalProfile() {
        let suite = "DevicesRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LibraryProfileRegistry(defaults: defaults)
        let local = registry.createLocal(
            name: "Local Library",
            managedMusicPath: "/tmp/local",
            sharingEnabled: true
        )
        let remote = registry.createRemote(
            name: "Mercury",
            hubID: UUID(),
            baseURL: URL(string: "https://aro-mercury.local:4848")!,
            policy: .stream
        )

        XCTAssertEqual(registry.activeProfileID, remote.id)
        registry.remove(remote.id)

        XCTAssertEqual(registry.profiles.count, 1)
        XCTAssertNil(registry.profiles.first { $0.id == remote.id })
        XCTAssertEqual(registry.activeProfileID, local.id)
    }

    func testRemovingInactiveProfileLeavesActiveProfileUntouched() {
        let suite = "DevicesRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LibraryProfileRegistry(defaults: defaults)
        let local = registry.createLocal(
            name: "Local Library",
            managedMusicPath: "/tmp/local",
            sharingEnabled: true
        )
        let remote = registry.createRemote(
            name: "Mercury",
            hubID: UUID(),
            baseURL: URL(string: "https://aro-mercury.local:4848")!,
            policy: .stream
        )
        registry.activate(local.id)

        registry.remove(remote.id)

        // Compared by identity, not by value: `activate` stamps `lastActivatedAt`, so the
        // profile held in the registry is legitimately no longer equal to the copy
        // returned before activation. The two differ below the precision `Date` prints at,
        // which made the failure read as "these identical values are not equal".
        XCTAssertEqual(registry.profiles.map(\.id), [local.id])
        XCTAssertEqual(registry.activeProfileID, local.id)
    }

    func testRemovingFinalProfileReturnsRegistryToFirstRunSetup() {
        let suite = "DevicesRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LibraryProfileRegistry(defaults: defaults)
        let remote = registry.createRemote(
            name: "Mercury",
            hubID: UUID(),
            baseURL: URL(string: "https://aro-mercury.local:4848")!,
            policy: .stream
        )
        registry.dismissSetup()

        registry.remove(remote.id)

        XCTAssertTrue(registry.profiles.isEmpty)
        XCTAssertNil(registry.activeProfileID)
        XCTAssertFalse(registry.setupDismissed)
        XCTAssertFalse(registry.isConfigured)
    }

    func testRepairingRemoteConnectionReusesReplicaProfile() {
        let suite = "DevicesRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LibraryProfileRegistry(defaults: defaults)
        let hubID = UUID()
        let original = registry.createRemote(
            name: "Mercury",
            hubID: hubID,
            baseURL: URL(string: "https://aro-mercury.local:4848")!,
            policy: .stream
        )

        let repaired = registry.upsertRemote(
            name: "Mercury Music",
            hubID: hubID,
            baseURL: URL(string: "https://mercury.example:4848")!,
            policy: .fullLibrary
        )

        XCTAssertEqual(repaired.id, original.id)
        XCTAssertEqual(repaired.databasePath, original.databasePath)
        XCTAssertEqual(repaired.mediaPath, original.mediaPath)
        XCTAssertEqual(registry.profiles.count, 1)
        XCTAssertEqual(repaired.name, "Mercury Music")
        XCTAssertEqual(
            repaired.baseURL,
            URL(string: "https://mercury.example:4848")
        )
        XCTAssertEqual(repaired.offlinePolicy, .fullLibrary)
    }

    func testRegistryRepairsDuplicateRemoteProfilesWithoutReplacingActiveReplica() {
        let suite = "DevicesRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hubID = UUID()
        var activeID: UUID!
        do {
            let registry = LibraryProfileRegistry(defaults: defaults)
            activeID = registry.createRemote(
                name: "Mercury original",
                hubID: hubID,
                baseURL: URL(string: "https://mercury.local:4848")!,
                policy: .stream
            ).id
            _ = registry.createRemote(
                name: "Mercury duplicate",
                hubID: hubID,
                baseURL: URL(string: "https://mercury.local:4848")!,
                policy: .stream
            )
            registry.activate(activeID)
            XCTAssertEqual(registry.profiles.count, 2)
        }

        let repaired = LibraryProfileRegistry(defaults: defaults)

        XCTAssertEqual(repaired.profiles.count, 1)
        XCTAssertEqual(repaired.activeProfileID, activeID)
        XCTAssertEqual(repaired.activeProfile?.name, "Mercury original")
    }

    func testRemoteOperationsCreatePlayableAuthoritativeRows() throws {
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
        let hubTrackID = UUID()
        let version = SyncFieldVersion(
            physicalMilliseconds: 1,
            logical: 0,
            deviceID: UUID()
        )
        store.upsertMembership(
            hub: AroHubInfo(
                hubID: hubID,
                displayName: "Jacob’s Library",
                protocolMin: 2,
                protocolMax: 4,
                pairingAvailable: false
            ),
            baseURL: URL(string: "https://aro-test.local:4848")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            replicaMode: .onDemand
        )
        let applied = try store.applyRemote(
            SequencedSyncOperation(
                sequence: 1,
                operationID: UUID(),
                deviceID: UUID(),
                entityType: "track",
                entityID: hubTrackID.uuidString,
                kind: "upsert",
                payload: .object([
                    "title": .string("A Song"),
                    "artist": .string("An Artist"),
                    "content_hash": .string(
                        String(repeating: "b", count: 64)
                    ),
                    "byte_count": .number(42),
                ]),
                fieldVersions: [
                    "title": version,
                    "artist": version,
                    "content_hash": version,
                    "byte_count": version,
                ]
            ),
            hubID: hubID
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(database.watchedFolders().map(\.id), [hubID])
        XCTAssertTrue(
            database.songs(folderID: hubID).isEmpty,
            "remote tracks remain hidden until server loudness arrives"
        )
        _ = try store.applyRemote(
            SequencedSyncOperation(
                sequence: 2,
                operationID: UUID(),
                deviceID: UUID(),
                entityType: "loudness",
                entityID: String(repeating: "b", count: 64) + ":2",
                kind: "upsert",
                payload: .object([
                    "content_hash": .string(String(repeating: "b", count: 64)),
                    "algorithm_version": .number(2),
                    "integrated_lufs": .number(-14),
                    "peak_amplitude": .number(0.8),
                    "analyzed_at": .number(1),
                ]),
                fieldVersions: [:]
            ),
            hubID: hubID
        )
        let song = try XCTUnwrap(database.songs(folderID: hubID).first)
        XCTAssertEqual(song.title, "A Song")
        XCTAssertEqual(
            song.url.absoluteString,
            "https://aro-test.local:4848/v1/blobs/"
                + String(repeating: "b", count: 64)
        )
        XCTAssertEqual(
            database.watchedFolders().first?.path,
            "https://aro-test.local:4848"
        )
    }

    func testRemoteLibraryFolderRepairsLegacyRootPath() throws {
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
        let hubID = UUID()
        let hub = AroHubInfo(
            hubID: hubID,
            displayName: "Mercury",
            protocolMin: 2,
            protocolMax: 4,
            pairingAvailable: false
        )
        let baseURL = URL(string: "https://mercury.local:4848")!
        let store = SQLiteSyncOperationStore(database: database)
        store.upsertMembership(
            hub: hub,
            baseURL: baseURL,
            tlsFingerprint: String(repeating: "a", count: 64),
            replicaMode: .onDemand
        )
        let contentHash = String(repeating: "b", count: 64)
        _ = try store.applyRemote(
            SequencedSyncOperation(
                sequence: 1,
                operationID: UUID(),
                deviceID: UUID(),
                entityType: "track",
                entityID: UUID().uuidString,
                kind: "upsert",
                payload: .object([
                    "title": .string("A Song"),
                    "artist": .string("An Artist"),
                    "content_hash": .string(contentHash),
                    "byte_count": .number(42),
                ]),
                fieldVersions: [:]
            ),
            hubID: hubID
        )
        _ = try store.applyRemote(
            SequencedSyncOperation(
                sequence: 2,
                operationID: UUID(),
                deviceID: UUID(),
                entityType: "loudness",
                entityID: contentHash + ":2",
                kind: "upsert",
                payload: .object([
                    "content_hash": .string(contentHash),
                    "algorithm_version": .number(2),
                    "integrated_lufs": .number(-14),
                    "peak_amplitude": .number(0.8),
                    "analyzed_at": .number(1),
                ]),
                fieldVersions: [:]
            ),
            hubID: hubID
        )
        XCTAssertEqual(database.songs(folderID: hubID).count, 1)

        database.save(
            folder: WatchedFolder(
                id: hubID,
                url: URL(fileURLWithPath: "/"),
                displayName: "Mercury",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        database.markFolderUnavailable(id: hubID)
        XCTAssertEqual(database.watchedFolders().first?.path, "/")
        XCTAssertTrue(database.songs(folderID: hubID).isEmpty)

        _ = SQLiteSyncOperationStore(database: database)

        XCTAssertEqual(
            database.watchedFolders().first?.path,
            baseURL.absoluteString
        )
        XCTAssertEqual(database.songs(folderID: hubID).count, 1)
    }

}
#endif
