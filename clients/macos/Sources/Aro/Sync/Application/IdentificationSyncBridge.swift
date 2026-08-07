import AroCommon
import Foundation

/// Location-neutral identification bridge. Local and cloud libraries both ask
/// their authority to resolve content hashes over authenticated HTTPS.
@MainActor
struct IdentificationSyncBridge {
    let profile: LibraryProfile?
    let syncStore: SQLiteSyncOperationStore
    let libraryDeviceID: UUID
    let localAdminToken: String?

    private var connection: LibraryServerConnection? {
        guard let profile else { return nil }
        return LibraryServerConnection.resolve(
            profile: profile,
            operations: syncStore,
            deviceID: libraryDeviceID,
            localAdminToken: localAdminToken
        )
    }

    /// Queues `songs` for (re-)identification. An active remote library always uses
    /// its hub: the bundled local helper cannot resolve that hub's files and would
    /// otherwise misleadingly report that zero songs were queued.
    @discardableResult
    func identify(_ songs: [Song]) async throws -> Int {
        guard let connection else { throw IdentificationSyncError.unreachable }
        let hashes = songs.compactMap(\.contentHash)
        guard !hashes.isEmpty else { return 0 }
        return try await connection.client.identifyTracks(
            contentHashes: hashes,
            credential: connection.credential
        )
    }

    /// The background queue's live status, from whichever transport is reachable —
    /// `nil` if neither is (e.g. the remote hub is temporarily offline).
    func status() async -> IdentificationStatus? {
        guard let connection else { return nil }
        return try? await connection.client.identificationStatus(
            credential: connection.credential
        )
    }
}

enum IdentificationSyncError: LocalizedError {
    case unreachable

    var errorDescription: String? {
        "Aro cannot reach the Background Service to sync metadata."
    }
}
