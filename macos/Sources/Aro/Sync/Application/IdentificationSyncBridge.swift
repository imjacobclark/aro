import AroCommon
import Foundation

/// Bridges "Sync Track/Album/All Data" actions to whichever transport can actually
/// reach `aro-server`: the local Unix control socket when this Mac is self-hosting,
/// or an authenticated HTTPS call to the active remote hub. Mirrors the same
/// local-vs-remote split `ContentView.resolveRemoteArtworkBlob`/
/// `pullIdentificationResults` already use for artwork and results — this is the
/// missing third leg: *triggering* identification, not just consuming its output.
/// Without this, "Sync Album Data"/"Sync All Music Metadata" silently did nothing for
/// a pure remote client, since the local control socket it exclusively used has no
/// route to a server on another machine.
///
/// `@MainActor` because `LibrarySettingsView.controlDataLocation` (main-actor isolated, like
/// the SwiftUI views it's normally called from) is used to resolve the local
/// transport — every real call site is already a `@MainActor` view, so this just
/// makes that isolation explicit rather than working around it.
@MainActor
struct IdentificationSyncBridge {
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

    /// Queues `songs` for (re-)identification. An active remote library always uses
    /// its hub: the bundled local helper cannot resolve that hub's files and would
    /// otherwise misleadingly report that zero songs were queued.
    @discardableResult
    func identify(_ songs: [Song]) async throws -> Int {
        if remoteProfile?.kind == .remote {
            guard let remoteContext else {
                throw IdentificationSyncError.unreachable
            }
            let hashes = songs.compactMap(\.contentHash)
            guard !hashes.isEmpty else { return 0 }
            return try await remoteContext.client.identifyTracks(
                contentHashes: hashes,
                credential: remoteContext.credential
            )
        }

        if let localClient {
            let targets = songs.compactMap { song -> IdentificationTarget? in
                guard let contentHash = song.contentHash, song.url.isFileURL else {
                    return nil
                }
                return IdentificationTarget(
                    contentHash: contentHash,
                    path: song.url.path
                )
            }
            guard !targets.isEmpty else { return 0 }
            try await localClient.identifyTracks(targets)
            return targets.count
        }

        throw IdentificationSyncError.unreachable
    }

    /// The background queue's live status, from whichever transport is reachable —
    /// `nil` if neither is (e.g. the remote hub is temporarily offline).
    func status() async -> IdentificationStatus? {
        if remoteProfile?.kind == .remote {
            guard let remoteContext else { return nil }
            return try? await remoteContext.client.identificationStatus(
                credential: remoteContext.credential
            )
        }
        if let localClient {
            return try? await localClient.identificationStatus()
        }
        return nil
    }
}

enum IdentificationSyncError: LocalizedError {
    case unreachable

    var errorDescription: String? {
        "Aro cannot reach the Background Service to sync metadata."
    }
}
