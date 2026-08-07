#if canImport(XCTest)
import AroCommon
import Foundation
import XCTest
@testable import Aro

final class LivePairingIntegrationTests: XCTestCase {
    func testCodeAuthenticatedPairingAgainstRustHub() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURLText = environment["ARO_LIVE_PAIRING_URL"],
              let baseURL = URL(string: baseURLText),
              let dataDirectory = environment["ARO_LIVE_PAIRING_DATA_DIR"] else {
            throw XCTSkip(
                "Set ARO_LIVE_PAIRING_URL and "
                    + "ARO_LIVE_PAIRING_DATA_DIR to run this integration test."
            )
        }

        let control = HubControlClient(
            socketURL: URL(fileURLWithPath: dataDirectory)
                .appendingPathComponent("control.sock")
        )
        let window = try await control.openPairing()
        XCTAssertEqual(window.code.count, 6)

        let deviceID = UUID()
        let pairingClient = AroSyncClient(pairingBaseURL: baseURL)
        let pairing = try await pairingClient.startPairing(
            deviceID: deviceID,
            deviceName: "Swift integration test",
            code: window.code
        )
        let pending = try await control.pendingPairingRequests()
        XCTAssertEqual(pending.map(\.requestID), [pairing.requestID])
        try await control.approvePairing(
            requestID: pairing.requestID,
            approve: true
        )

        let result = try await pairingClient.pollPairing(pairing: pairing)
        guard case .approved(let completed) = result else {
            return XCTFail("Expected an approved pairing result")
        }
        XCTAssertEqual(completed.credential.deviceID, deviceID)
        XCTAssertEqual(completed.tlsFingerprint.count, 64)

        let pinnedClient = AroSyncClient(
            baseURL: baseURL,
            pinnedTLSFingerprint: completed.tlsFingerprint
        )
        // Asserted against the version this client actually speaks rather than a literal:
        // pinning the number here meant every protocol bump broke a test that has nothing
        // to do with the bump, which is how it came to be failing for the wrong reason.
        // What matters is that a real Rust hub and this client agree on a usable range.
        let info = try await pinnedClient.hubInfo()
        XCTAssertLessThanOrEqual(info.protocolMin, AroSyncProtocol.currentVersion)
        XCTAssertGreaterThanOrEqual(info.protocolMax, AroSyncProtocol.currentVersion)
        _ = try await pinnedClient.compatibleHubInfo()
    }
}
#endif
