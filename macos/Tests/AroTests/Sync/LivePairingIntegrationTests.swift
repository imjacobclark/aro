#if canImport(XCTest)
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
        let info = try await pinnedClient.hubInfo()
        XCTAssertEqual(info.protocolMin, 2)
        XCTAssertEqual(info.protocolMax, 4)
    }
}
#endif
