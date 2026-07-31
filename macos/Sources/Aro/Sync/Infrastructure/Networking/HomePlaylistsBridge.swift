import AroCommon
import Foundation
import OSLog

/// Fetches the Home screen's auto-generated playlists from whichever transport can
/// actually reach `aro-server`: the local Unix control socket when this Mac is
/// self-hosting, or an authenticated HTTPS call to the active remote hub. Mirrors
/// `IdentificationSyncBridge`'s local-vs-remote split exactly — the server is the
/// canonical generator (it owns the listening analytics, favourites, and MusicBrainz
/// mood tags that drive them); this app only maps the returned content hashes onto its
/// local catalog and renders.
///
/// `@MainActor` for the same reason as `IdentificationSyncBridge`: the local transport
/// is resolved via `LibrarySettingsView.controlDataLocation` (main-actor isolated), and
/// every real call site is already a `@MainActor` view.
@MainActor
struct HomePlaylistsBridge {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "HomePlaylists"
    )

    let dataLocation: String
    let localServers: [LocalAroServer]
    let remoteProfile: LibraryProfile?
    let syncStore: SQLiteSyncOperationStore
    let libraryDeviceID: UUID

    private var localClient: HubControlClient? {
        let resolved = LibrarySettingsView.controlDataLocation(
            preferred: dataLocation,
            servers: localServers
        )
        guard let resolved, !resolved.isEmpty else { return nil }
        return HubControlClient(
            socketURL: URL(fileURLWithPath: resolved)
                .appendingPathComponent("control.sock")
        )
    }

    private var remoteContext: (client: AroSyncClient, credential: HubDeviceCredential)? {
        guard let remoteProfile,
              remoteProfile.kind == .remote,
              let hubID = remoteProfile.hubID,
              let baseURL = remoteProfile.baseURL,
              let membership = syncStore.membership(baseURL: baseURL),
              let credential = try? FileHubCredentialStore().load(
                hubID: hubID,
                deviceID: libraryDeviceID
              )
        else {
            return nil
        }
        return (
            AroSyncClient(
                baseURL: baseURL,
                pinnedTLSFingerprint: membership.tlsFingerprint
            ),
            credential
        )
    }

    /// The hub's current playlists, from whichever transport is reachable — empty when
    /// neither is (e.g. the background service hasn't finished starting yet, or the
    /// remote hub is temporarily offline). Home just shows its empty state until the
    /// next poll succeeds; there is deliberately no client-side generation fallback.
    func playlists() async -> [ServerGeneratedPlaylist] {
        if remoteProfile?.kind == .remote {
            guard let remoteContext else {
                Self.logger.debug("playlists: no remote context available")
                return []
            }
            do {
                return try await remoteContext.client.playlists(
                    credential: remoteContext.credential
                )
            } catch {
                Self.logger.error(
                    "playlists: remote fetch failed: \(String(describing: error), privacy: .public)"
                )
                return []
            }
        }
        if let localClient {
            do {
                return try await localClient.playlists()
            } catch {
                Self.logger.error(
                    "playlists: local fetch failed: \(String(describing: error), privacy: .public)"
                )
                return []
            }
        }
        Self.logger.debug("playlists: no local client available")
        return []
    }

    /// Tier 3 "seed-track radio" (see `aro-server`'s `playlists::radio`) — the tracks
    /// most similar to `contentHash`, nearest first, seed itself in front. `nil` if
    /// no server is reachable or the seed hasn't been analyzed yet.
    func radio(contentHash: String, limit: Int = 30) async -> ServerGeneratedPlaylist? {
        if remoteProfile?.kind == .remote {
            guard let remoteContext else {
                Self.logger.debug("radio: no remote context available")
                return nil
            }
            do {
                return try await remoteContext.client.radio(
                    contentHash: contentHash,
                    limit: limit,
                    credential: remoteContext.credential
                )
            } catch {
                Self.logger.error(
                    "radio: remote fetch failed: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        if let localClient {
            do {
                return try await localClient.radio(contentHash: contentHash, limit: limit)
            } catch {
                Self.logger.error(
                    "radio: local fetch failed: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        Self.logger.debug("radio: no local client available")
        return nil
    }
}
