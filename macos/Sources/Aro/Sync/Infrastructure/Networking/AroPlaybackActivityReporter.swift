import AroCommon
import Foundation

final class AroPlaybackActivityReporter:
    PlaybackActivityReporting,
    @unchecked Sendable
{
    private let client: AroSyncClient
    private let credential: HubDeviceCredential?

    init(client: AroSyncClient, credential: HubDeviceCredential?) {
        self.client = client
        self.credential = credential
    }

    func report(_ snapshot: PlaybackActivitySnapshot) {
        Task {
            // Live intelligence is deliberately best-effort. Local listening
            // history and its sync outbox remain the durable source of truth.
            try? await client.reportPlaybackActivity(
                snapshot,
                credential: credential
            )
        }
    }
}
