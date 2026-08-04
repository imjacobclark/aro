import AroCommon
import Foundation

/// A location-neutral session with the library authority. `isLocallyHosted`
/// affects helper recovery and admin capabilities only; catalogue and media
/// consumers use the same HTTPS client in both cases.
struct LibraryServerConnection: Sendable {
    let hubID: UUID
    let baseURL: URL
    let tlsFingerprint: String
    let client: AroSyncClient
    let credential: HubDeviceCredential?
    let mediaCredential: HubDeviceCredential
    let isLocallyHosted: Bool

    @MainActor
    static func resolve(
        profile: LibraryProfile,
        operations: SQLiteSyncOperationStore,
        deviceID: UUID,
        localAdminToken: String?
    ) -> LibraryServerConnection? {
        guard let hubID = profile.hubID,
              let baseURL = profile.baseURL,
              let membership = operations.membership(baseURL: baseURL) else {
            return nil
        }

        if profile.kind == .local {
            guard let localAdminToken, !localAdminToken.isEmpty else {
                return nil
            }
            return LibraryServerConnection(
                hubID: hubID,
                baseURL: baseURL,
                tlsFingerprint: membership.tlsFingerprint,
                client: AroSyncClient(
                    localAdminBaseURL: baseURL,
                    adminToken: localAdminToken,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                ),
                credential: nil,
                mediaCredential: HubDeviceCredential(
                    deviceID: deviceID,
                    credential: localAdminToken
                ),
                isLocallyHosted: true
            )
        }

        guard let credential = try? FileHubCredentialStore().load(
            hubID: hubID,
            deviceID: deviceID
        ) else {
            return nil
        }
        return LibraryServerConnection(
            hubID: hubID,
            baseURL: baseURL,
            tlsFingerprint: membership.tlsFingerprint,
            client: AroSyncClient(
                baseURL: baseURL,
                pinnedTLSFingerprint: membership.tlsFingerprint
            ),
            credential: credential,
            mediaCredential: credential,
            isLocallyHosted: false
        )
    }
}
