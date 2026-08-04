import AroCommon
import Foundation
import OSLog

/// Server-generated Home data over the same authenticated HTTPS connection
/// regardless of where the library server runs.
@MainActor
struct HomePlaylistsBridge {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "HomePlaylists"
    )

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

    /// The hub's current playlists, from whichever transport is reachable — empty when
    /// neither is (e.g. the background service hasn't finished starting yet, or the
    /// remote hub is temporarily offline). Home just shows its empty state until the
    /// next poll succeeds; there is deliberately no client-side generation fallback.
    func playlists() async -> [ServerGeneratedPlaylist] {
        guard let connection else { return [] }
        do {
            return try await connection.client.playlists(
                credential: connection.credential
            )
        } catch {
            Self.logger.error(
                "playlists fetch failed: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Reorders a queue by measured audio similarity. Returns `nil` when no hub is
    /// reachable, so callers keep whatever order they already had rather than
    /// treating an outage as "shuffle produced nothing".
    func smartShuffle(contentHashes: [String], start: String?) async -> [String]? {
        guard let connection else { return nil }
        return try? await connection.client.smartShuffle(
            contentHashes: contentHashes,
            start: start,
            credential: connection.credential
        )
    }

    /// Tier 3 "seed-track radio" (see `aro-server`'s `playlists::radio`) — the tracks
    /// most similar to `contentHash`, nearest first, seed itself in front. `nil` if
    /// no server is reachable or the seed hasn't been analyzed yet.
    func radio(contentHash: String, limit: Int = 30) async -> ServerGeneratedPlaylist? {
        guard let connection else { return nil }
        do {
            return try await connection.client.radio(
                contentHash: contentHash,
                limit: limit,
                credential: connection.credential
            )
        } catch {
            Self.logger.error(
                "radio fetch failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}
