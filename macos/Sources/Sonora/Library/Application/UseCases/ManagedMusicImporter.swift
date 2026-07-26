import CryptoKit
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
                guard !knownHashes.contains(hash) else {
                    duplicates += 1
                    continue
                }
                let staged = staging.appendingPathComponent(
                    file.lastPathComponent
                )
                try FileManager.default.copyItem(at: file, to: staged)
                let destination = Self.collisionSafeDestination(
                    for: file,
                    hash: hash,
                    in: library
                )
                try FileManager.default.moveItem(
                    at: staged,
                    to: destination
                )
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

    private static func collisionSafeDestination(
        for source: URL,
        hash: String,
        in library: URL
    ) -> URL {
        let preferred = library.appendingPathComponent(
            source.lastPathComponent
        )
        guard FileManager.default.fileExists(atPath: preferred.path) else {
            return preferred
        }
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension
        let name = "\(stem)-\(hash.prefix(8))"
        return library.appendingPathComponent(name)
            .appendingPathExtension(suffix)
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
