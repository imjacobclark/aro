import Foundation
import AroCommon

/// Result of one `synchronize()` pass, for surfacing progress/diagnostics.
struct LocalHubSyncResult: Sendable {
    let appliedOperations: Int
    let cursor: UInt64
}

/// Replicates this Mac's own local hub (the bundled `aro-server`, running as the
/// Background Service against this same machine's own data) into the local
/// library database, over the control socket instead of HTTPS.
///
/// This is the local-profile analogue of `HubSyncCoordinator`, but deliberately
/// not a retrofit of it: `HubSyncCoordinator.synchronize()` is built around
/// paired-device semantics that don't apply here -- a device credential,
/// `deviceAccess` contribution checks, blob uploads for contributed music, and
/// source-health reporting. A same-machine hub needs none of that: it already
/// has the bytes (this app never uploads anything to itself), and there is no
/// pairing to authenticate. So this coordinator only does the one thing that's
/// actually meaningful locally: pull the hub's operation log and apply it,
/// pull-only, no push -- scan-derived library data (title, artist, loudness,
/// identification) is server-authored, and personal per-device state
/// (favourites, play counts, listening history) never needs to leave this Mac
/// in the first place, so there is nothing this coordinator ever needs to push.
actor LocalHubReplicaCoordinator {
    private let hubID: UUID
    private let client: HubControlClient
    private let operations: SQLiteSyncOperationStore

    init(
        hubID: UUID,
        client: HubControlClient,
        operations: SQLiteSyncOperationStore
    ) {
        self.hubID = hubID
        self.client = client
        self.operations = operations
    }

    func synchronize() async throws -> LocalHubSyncResult {
        let status = try await client.status()
        operations.ensureLocalHubMembership(
            hubID: hubID,
            displayName: status.displayName
        )
        var cursor = operations.localHubServerCursor(hubID: hubID)
        var applied = 0

        while true {
            try Task.checkCancellation()
            let page = try await client.changesAfter(cursor)
            if page.isEmpty { break }

            for sequenced in page {
                try Task.checkCancellation()
                let localPath = try await resolvedPath(for: sequenced)
                if try operations.applyLocalHub(
                    sequenced,
                    hubID: hubID,
                    localPath: localPath
                ) {
                    applied += 1
                }
                cursor = max(cursor, sequenced.sequence)
            }
        }

        return LocalHubSyncResult(appliedOperations: applied, cursor: cursor)
    }

    /// Resolves a `track` operation's content hash to its on-disk path via the
    /// control socket. Best-effort: a track that's since been tombstoned or
    /// whose blob is temporarily unavailable simply applies with no path rather
    /// than failing the whole sync pass -- the metadata is still worth having,
    /// and a later pass (or a future rescan) can fill the path in.
    private func resolvedPath(
        for sequenced: SequencedSyncOperation
    ) async throws -> String? {
        guard sequenced.entityType == "track",
              sequenced.kind == "upsert",
              case .object(let payload) = sequenced.payload,
              case .string(let hash)? = payload["content_hash"] else {
            return nil
        }
        return try? await client.trackLocation(hash: hash)
    }
}
