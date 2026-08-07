import Darwin
import Foundation

enum LocalHubSecretError: LocalizedError {
    case invalidRecord
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "Aro could not read the saved Background Service secrets."
        case .fileSystem(let message):
            "Aro could not securely save the Background Service secrets: \(message)"
        }
    }
}

/// Persists the local hub's admin token and AcoustID API key without
/// involving UserDefaults, mirroring `FileHubCredentialStore`'s mechanics
/// (0700 directory, 0600 file, atomic rename, excluded from backups). These
/// are authentication/API secrets for the machine's own Background Service,
/// not per-pairing credentials, so they're keyed by a fixed filename rather
/// than by hub ID. Must never be logged or included in diagnostics.
struct LocalHubSecretStore {
    struct Record: Codable {
        var adminToken: String
        var acoustidApiKey: String
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

    func load() throws -> Record? {
        let url = secretsURL
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        try prepareDirectory()
        try setPermissions(0o600, at: url)
        do {
            return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        } catch {
            throw LocalHubSecretError.invalidRecord
        }
    }

    func save(_ record: Record) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(record)
        let destination = secretsURL
        let temporary = directory.appendingPathComponent(
            ".local-hub-secrets.\(UUID().uuidString).tmp"
        )

        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LocalHubSecretError.fileSystem("could not create the file")
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let status = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard status == 0 else {
            throw LocalHubSecretError.fileSystem(String(cString: strerror(errno)))
        }
        try setPermissions(0o600, at: destination)
    }

    private var secretsURL: URL {
        directory.appendingPathComponent("local-hub-secrets.json", isDirectory: false)
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
            throw LocalHubSecretError.fileSystem(error.localizedDescription)
        }
    }
}
