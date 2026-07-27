import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct ManagedImportResult: Sendable {
    let importedFiles: Int
    let skippedDuplicates: Int
}

struct ManagedMusicImporter: Sendable {
    func importFolder(
        _ source: URL,
        into library: URL
    ) async throws -> ManagedImportResult {
        try await Task.detached {
            try FileManager.default.createDirectory(
                at: library,
                withIntermediateDirectories: true
            )
            let staging = library.appendingPathComponent(
                ".sonora-import-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: staging) }

            let existingHashes = try Self.hashes(in: library)
            var knownHashes = existingHashes
            var imported = 0
            var duplicates = 0
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .contentTypeKey,
            ]
            let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let file = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true,
                      values.contentType?.conforms(to: .audio) == true else {
                    continue
                }
                let hash = try Self.sha256(file)
                let relative = String(
                    file.path.dropFirst(source.path.count)
                ).trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
                let destination = library.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: destination.path),
                   (try? Self.sha256(destination)) == hash {
                    duplicates += 1
                    continue
                }
                if knownHashes.contains(hash),
                   !FileManager.default.fileExists(atPath: destination.path) {
                    duplicates += 1
                    continue
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let staged = staging.appendingPathComponent(
                    "\(UUID().uuidString)-\(file.lastPathComponent)"
                )
                try FileManager.default.copyItem(at: file, to: staged)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try Self.replaceAtomically(
                        destination,
                        with: staged
                    )
                } else {
                    try FileManager.default.moveItem(
                        at: staged,
                        to: destination
                    )
                }
                knownHashes.insert(hash)
                imported += 1
            }
            return ManagedImportResult(
                importedFiles: imported,
                skippedDuplicates: duplicates
            )
        }.value
    }

    private static func hashes(in folder: URL) throws -> Set<String> {
        var hashes: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let file = enumerator?.nextObject() as? URL {
            guard (try? file.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true else {
                continue
            }
            if let hash = try? sha256(file) {
                hashes.insert(hash)
            }
        }
        return hashes
    }

    private static func replaceAtomically(
        _ destination: URL,
        with staged: URL
    ) throws {
        let result = staged.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSFilePathErrorKey: destination.path,
                ]
            )
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}
