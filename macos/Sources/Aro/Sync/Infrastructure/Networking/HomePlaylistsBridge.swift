import AroCommon
import Foundation

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
            guard let remoteContext else { return [] }
            return (try? await remoteContext.client.playlists(
                credential: remoteContext.credential
            )) ?? []
        }
        if let localClient {
            return (try? await localClient.playlists()) ?? []
        }
        return []
    }
}
