import AroCommon
import Darwin
import Foundation

enum HubCredentialError: LocalizedError {
    case missingRecord
    case invalidRecord
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .missingRecord:
            "This library connection needs to be repaired."
        case .invalidRecord:
            "Aro could not read the saved library credential."
        case .fileSystem(let message):
            "Aro could not securely save the library credential: \(message)"
        }
    }
}

/// Persists pairing credentials without involving the macOS Keychain.
///
/// The directory is private to the current user (0700) and each credential is
/// stored in its own 0600 file. The credential is still an authentication
/// secret, so it must never be logged or included in diagnostics.
struct FileHubCredentialStore {
    private struct Record: Codable {
        let deviceID: UUID
        let credential: String
    }

    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else if let testRoot = ProcessInfo.processInfo.environment[
            "ARO_UI_TEST_ROOT"
        ] {
            self.directory = URL(
                fileURLWithPath: testRoot,
                isDirectory: true
            ).appendingPathComponent("Credentials", isDirectory: true)
        } else {
            self.directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
                .appendingPathComponent("Aro", isDirectory: true)
                .appendingPathComponent("Credentials", isDirectory: true)
        }
    }

    func save(_ credential: HubDeviceCredential, hubID: UUID) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(
            Record(
                deviceID: credential.deviceID,
                credential: credential.credential
            )
        )
        let destination = credentialURL(hubID: hubID)
        let temporary = directory.appendingPathComponent(
            ".\(hubID.uuidString.lowercased()).\(UUID().uuidString).tmp"
        )

        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw HubCredentialError.fileSystem("could not create the file")
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let status = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard status == 0 else {
            throw HubCredentialError.fileSystem(
                String(cString: strerror(errno))
            )
        }
        try setPermissions(0o600, at: destination)
    }

    func load(hubID: UUID, deviceID: UUID) throws -> HubDeviceCredential? {
        let url = credentialURL(hubID: hubID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        try prepareDirectory()
        try setPermissions(0o600, at: url)
        let record: Record
        do {
            record = try JSONDecoder().decode(
                Record.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw HubCredentialError.invalidRecord
        }
        guard record.deviceID == deviceID else {
            return nil
        }
        return HubDeviceCredential(
            deviceID: record.deviceID,
            credential: record.credential
        )
    }

    func remove(hubID: UUID) throws {
        let url = credentialURL(hubID: hubID)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func credentialURL(hubID: UUID) -> URL {
        directory.appendingPathComponent(
            "\(hubID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, at: directory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        } catch {
            throw HubCredentialError.fileSystem(error.localizedDescription)
        }
    }
}
