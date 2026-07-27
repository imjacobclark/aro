#if canImport(Testing)
import AroCommon
import Foundation
import Testing
@testable import Aro

@Suite("File credential storage")
struct FileHubCredentialStoreTests {
    @Test("Credentials round-trip with private permissions and can be removed")
    func saveLoadAndRemove() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "Credentials",
            isDirectory: true
        )
        let store = FileHubCredentialStore(directory: directory)
        let hubID = UUID()
        let deviceID = UUID()
        let credential = HubDeviceCredential(
            deviceID: deviceID,
            credential: "private-test-token"
        )

        try store.save(credential, hubID: hubID)

        #expect(
            try store.load(hubID: hubID, deviceID: deviceID)?.credential
                == credential.credential
        )
        #expect(try permissions(at: directory) & 0o777 == 0o700)
        #expect(
            try permissions(
                at: directory.appendingPathComponent(
                    "\(hubID.uuidString.lowercased()).json"
                )
            ) & 0o777 == 0o600
        )

        try store.remove(hubID: hubID)
        #expect(try store.load(hubID: hubID, deviceID: deviceID) == nil)
    }

    @Test("Credentials stay bound to the device that paired")
    func rejectsAnotherDevice() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileHubCredentialStore(directory: root)
        let hubID = UUID()
        try store.save(
            HubDeviceCredential(
                deviceID: UUID(),
                credential: "private-test-token"
            ),
            hubID: hubID
        )

        #expect(try store.load(hubID: hubID, deviceID: UUID()) == nil)
    }

    @Test("Overly broad file permissions are repaired before reading")
    func repairsPermissions() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileHubCredentialStore(directory: root)
        let hubID = UUID()
        let deviceID = UUID()
        try store.save(
            HubDeviceCredential(
                deviceID: deviceID,
                credential: "private-test-token"
            ),
            hubID: hubID
        )
        let credentialURL = root.appendingPathComponent(
            "\(hubID.uuidString.lowercased()).json"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: credentialURL.path
        )

        #expect(try store.load(hubID: hubID, deviceID: deviceID) != nil)
        #expect(try permissions(at: credentialURL) & 0o777 == 0o600)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }
}
#endif
