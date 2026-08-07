import Foundation

struct LibraryDataMigrationResult: Sendable {
    let profile: LibraryProfile
    let serverDataPath: String
    let root: URL
    let retainedPaths: [String]
}

struct LibraryDataMigrator: Sendable {
    /// Moves this Mac's own local library (database, media, Aro-managed music) and,
    /// if a Background Service is configured, its server data directory.
    ///
    /// The server portion runs through the bundled `aro-server migrate` subprocess
    /// rather than being copied here: that command checkpoints the store, verifies
    /// every blob before *and* after copying, and only swaps in the new location
    /// once both verifications pass — a guarantee this method cannot reproduce with
    /// a plain file copy. It runs first, before anything local-only is touched, so a
    /// failure there leaves the Mac's own library completely untouched.
    func migrate(
        profile: LibraryProfile,
        libraryFiles: any LibraryFileManaging,
        serverDataPath: String,
        serverConfigPath: String,
        serverBinaryURL: URL?,
        into parent: URL
    ) async throws -> LibraryDataMigrationResult {
        let safeName = profile.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let destination = parent.appendingPathComponent(
            "\(safeName.isEmpty ? "Aro" : safeName)-Library-Data",
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryDataMigrationError.destinationExists(destination.path)
        }
        let stage = parent.appendingPathComponent(
            ".aro-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        let oldPaths = Set(
            [
                profile.databasePath,
                profile.mediaPath,
                profile.managedMusicPath,
                serverDataPath.isEmpty ? nil : serverDataPath,
            ].compactMap { $0 }
        )
        let standardizedDestination = destination.standardizedFileURL.path
        if oldPaths.contains(where: {
            let old = URL(fileURLWithPath: $0).standardizedFileURL.path
            return standardizedDestination == old
                || standardizedDestination.hasPrefix(old + "/")
                || old.hasPrefix(standardizedDestination + "/")
        }) {
            throw LibraryDataMigrationError.invalidNesting
        }
        let required = try oldPaths.reduce(Int64(0)) {
            $0 + (try allocatedSize(URL(fileURLWithPath: $1)))
        }
        let values = try parent.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let free = values.volumeAvailableCapacityForImportantUsage,
           required > free {
            throw LibraryDataMigrationError.insufficientSpace(
                required: required,
                available: free
            )
        }

        let server = destination.appendingPathComponent(
            "Server",
            isDirectory: true
        )
        if !serverDataPath.isEmpty {
            guard let serverBinaryURL,
                  FileManager.default.isExecutableFile(atPath: serverBinaryURL.path)
            else {
                throw LibraryDataMigrationError.serverBinaryUnavailable
            }
            try await runServerMigrate(
                binaryURL: serverBinaryURL,
                configPath: serverConfigPath,
                destination: server
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: stage,
                withIntermediateDirectories: true
            )
            let database = stage.appendingPathComponent("Library.sqlite3")
            try libraryFiles.exportLibrary(to: database)

            let media = stage.appendingPathComponent("Media", isDirectory: true)
            try copyIfPresent(
                URL(fileURLWithPath: profile.mediaPath),
                to: media
            )
            let music: URL?
            if let managedMusicPath = profile.managedMusicPath {
                let target = stage.appendingPathComponent(
                    "Music",
                    isDirectory: true
                )
                try copyIfPresent(
                    URL(fileURLWithPath: managedMusicPath),
                    to: target
                )
                music = target
            } else {
                music = nil
            }
            guard FileManager.default.fileExists(atPath: database.path) else {
                throw LibraryDataMigrationError.verificationFailed
            }
            // `moveItem(at:to:)` requires `destination` not to already exist. When
            // the server step above ran, it already created `destination/Server` (and
            // therefore `destination` itself), so each local item is moved in
            // individually instead of swapping the whole staged directory in at once.
            if FileManager.default.fileExists(atPath: destination.path) {
                for name in try FileManager.default.contentsOfDirectory(atPath: stage.path) {
                    try FileManager.default.moveItem(
                        at: stage.appendingPathComponent(name),
                        to: destination.appendingPathComponent(name)
                    )
                }
                try FileManager.default.removeItem(at: stage)
            } else {
                try FileManager.default.moveItem(at: stage, to: destination)
            }

            var updated = profile
            updated.databasePath = destination
                .appendingPathComponent("Library.sqlite3").path
            updated.mediaPath = destination
                .appendingPathComponent("Media", isDirectory: true).path
            if music != nil {
                updated.managedMusicPath = destination
                    .appendingPathComponent("Music", isDirectory: true).path
            }
            return LibraryDataMigrationResult(
                profile: updated,
                serverDataPath: serverDataPath.isEmpty ? "" : server.path,
                root: destination,
                retainedPaths: oldPaths.sorted()
            )
        } catch {
            // `destination` is deliberately left alone: if the server step above
            // ran, it may already hold validly migrated, verified server data that
            // would be unrecoverable if deleted here.
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    private func runServerMigrate(
        binaryURL: URL,
        configPath: String,
        destination: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = [
                "--config", configPath,
                "migrate", "--to", destination.path,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LibraryDataMigrationError.serverMigrateFailed(
                    output.isEmpty
                        ? "aro-server migrate exited with status \(process.terminationStatus)."
                        : output
                )
            }
        }.value
    }

    private func copyIfPresent(
        _ source: URL,
        to destination: URL,
        excluding names: Set<String> = []
    ) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            return
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if names.contains(item.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            let relative = String(
                item.path.dropFirst(source.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = destination.appendingPathComponent(relative)
            let isDirectory = try item.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory == true
            if isDirectory {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    private func allocatedSize(_ url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
        ]
        var total: Int64 = 0
        if let values = try? url.resourceValues(forKeys: keys),
           values.isRegularFile == true {
            return Int64(values.fileAllocatedSize ?? 0)
        }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        )
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                total += Int64(values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

enum LibraryDataMigrationError: LocalizedError {
    case destinationExists(String)
    case insufficientSpace(required: Int64, available: Int64)
    case verificationFailed
    case invalidNesting
    case serverBinaryUnavailable
    case serverMigrateFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let path):
            "Library Data already exists at \(path). Choose another folder."
        case .insufficientSpace(let required, let available):
            "Migration needs \(required) bytes but only \(available) bytes are available."
        case .verificationFailed:
            "The copied Library Data could not be verified."
        case .invalidNesting:
            "The new Library Data location cannot contain an existing "
                + "Aro data location, or be inside one."
        case .serverBinaryUnavailable:
            "The Background Service's aro-server binary is not included in this "
                + "build, so its Library Data could not be moved."
        case .serverMigrateFailed(let message):
            "Moving the Background Service's Library Data failed: \(message)"
        }
    }
}
