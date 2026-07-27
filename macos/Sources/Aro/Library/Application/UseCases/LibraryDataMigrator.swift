import Foundation

struct LibraryDataMigrationResult: Sendable {
    let profile: LibraryProfile
    let serverDataPath: String
    let root: URL
    let retainedPaths: [String]
}

struct LibraryDataMigrator: Sendable {
    func migrate(
        profile: LibraryProfile,
        libraryFiles: any LibraryFileManaging,
        serverDataPath: String,
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
            let server = stage.appendingPathComponent(
                "Server",
                isDirectory: true
            )
            if !serverDataPath.isEmpty {
                try copyIfPresent(
                    URL(fileURLWithPath: serverDataPath),
                    to: server,
                    excluding: ["control.sock", "instance.lock"]
                )
            }
            guard FileManager.default.fileExists(atPath: database.path) else {
                throw LibraryDataMigrationError.verificationFailed
            }
            try FileManager.default.moveItem(at: stage, to: destination)

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
                serverDataPath: destination
                    .appendingPathComponent("Server", isDirectory: true).path,
                root: destination,
                retainedPaths: oldPaths.sorted()
            )
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
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
        }
    }
}
