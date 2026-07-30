import CryptoKit
import Foundation
import AroCommon

struct LibraryExportProgress: Sendable {
    let completedTracks: Int
    let totalTracks: Int
    let currentTrack: String
}

struct LibraryExportResult: Sendable {
    let rootURL: URL
    let exportedTracks: Int
    let unchangedTracks: Int
}

enum LibraryExportError: LocalizedError {
    case invalidSourceFile(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceFile(let name):
            "The library returned incomplete data for “\(name)”."
        case .checksumMismatch(let name):
            "The downloaded bytes for “\(name)” did not match the library."
        }
    }
}

actor AroLibraryExporter {
    private let client: AroSyncClient
    private let credential: HubDeviceCredential?
    private let fileManager = FileManager.default
    // Fallback source used when the library host can't be reached. A
    // Resilient (full-library) profile already mirrors every track's bytes
    // locally, so export shouldn't have to depend on the host being alive —
    // only the manifest and any not-yet-cached bytes do.
    private let localSongs: [Song]
    private let localMediaCache: SQLiteMediaCache?

    init(
        client: AroSyncClient,
        credential: HubDeviceCredential?,
        localSongs: [Song] = [],
        localMediaCache: SQLiteMediaCache? = nil
    ) {
        self.client = client
        self.credential = credential
        self.localSongs = localSongs
        self.localMediaCache = localMediaCache
    }

    func export(
        to destination: URL,
        progress: @escaping @Sendable (LibraryExportProgress) async -> Void
    ) async throws -> LibraryExportResult {
        let manifest = try await resolvedManifest()
        let root = destination.appendingPathComponent(
            "aro-library",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        var pathsByKey: [String: String] = [:]
        var exported = 0
        var unchanged = 0
        for (index, track) in manifest.tracks.enumerated() {
            try Task.checkCancellation()
            await progress(
                LibraryExportProgress(
                    completedTracks: index,
                    totalTracks: manifest.tracks.count,
                    currentTrack: track.title
                )
            )
            let target = uniqueTarget(
                for: track,
                root: root,
                pathsByKey: &pathsByKey
            )
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if try fileMatches(target, track: track) {
                unchanged += 1
                continue
            }
            try await download(track, to: target)
            exported += 1
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("aro-manifest.json"),
            options: .atomic
        )
        await progress(
            LibraryExportProgress(
                completedTracks: manifest.tracks.count,
                totalTracks: manifest.tracks.count,
                currentTrack: "Complete"
            )
        )
        return LibraryExportResult(
            rootURL: root,
            exportedTracks: exported,
            unchangedTracks: unchanged
        )
    }

    /// Prefers the host's manifest when reachable (it carries richer
    /// metadata, e.g. track/disc numbers, than the local library alone).
    /// Falls back to a manifest built from the local library so export
    /// still works with the host offline, provided this device has its own
    /// copy of the songs to draw from.
    private func resolvedManifest() async throws -> AroExportManifest {
        do {
            return try await client.exportManifest(credential: credential)
        } catch {
            guard !localSongs.isEmpty else {
                throw error
            }
            return localManifest()
        }
    }

    private func localManifest() -> AroExportManifest {
        let tracks = localSongs.compactMap { song -> AroExportTrack? in
            guard let hash = song.fileFingerprint?.contentHash,
                  let byteCount = song.fileSizeBytes else {
                return nil
            }
            return AroExportTrack(
                trackID: song.libraryID,
                contentHash: hash,
                byteCount: UInt64(byteCount),
                title: song.title,
                artist: song.artist,
                album: song.album,
                trackNumber: nil,
                discNumber: nil,
                originalFilename: song.url.lastPathComponent,
                originalExtension: song.url.pathExtension,
                removedAt: nil
            )
        }
        return AroExportManifest(
            schemaVersion: 1,
            libraryName: "Library",
            generatedAt: Date(),
            tracks: tracks
        )
    }

    private func download(
        _ track: AroExportTrack,
        to target: URL
    ) async throws {
        let partial = target.appendingPathExtension("aro-part")
        if let cachedURL = localMediaCache?.localURL(hash: track.contentHash),
           fileManager.fileExists(atPath: cachedURL.path) {
            try? fileManager.removeItem(at: partial)
            try fileManager.copyItem(at: cachedURL, to: partial)
        } else {
            let currentSize = fileSize(partial)
            if currentSize > track.byteCount {
                try fileManager.removeItem(at: partial)
            }
            let offset = min(fileSize(partial), track.byteCount)
            if offset < track.byteCount {
                let bytes = try await client.downloadBlob(
                    hash: track.contentHash,
                    from: offset,
                    credential: credential
                )
                if offset == 0 {
                    try bytes.write(to: partial, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: partial)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                }
            }
        }
        guard fileSize(partial) == track.byteCount else {
            throw LibraryExportError.invalidSourceFile(track.title)
        }
        guard try sha256(partial) == track.contentHash.lowercased() else {
            throw LibraryExportError.checksumMismatch(track.title)
        }
        try fileManager.moveItem(at: partial, to: target)
    }

    private func fileMatches(
        _ url: URL,
        track: AroExportTrack
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              fileSize(url) == track.byteCount else {
            return false
        }
        return try sha256(url) == track.contentHash.lowercased()
    }

    private func uniqueTarget(
        for track: AroExportTrack,
        root: URL,
        pathsByKey: inout [String: String]
    ) -> URL {
        var directory = root
        if track.removedAt != nil {
            directory.appendPathComponent("_Recently Removed", isDirectory: true)
        }
        directory.appendPathComponent(
            sanitized(track.artist, fallback: "Unknown Artist"),
            isDirectory: true
        )
        directory.appendPathComponent(
            sanitized(track.album ?? "", fallback: "Unknown Album"),
            isDirectory: true
        )
        let number: String
        if let trackNumber = track.trackNumber {
            let trackText = String(format: "%02d", trackNumber)
            number = (track.discNumber ?? 1) > 1
                ? "\(track.discNumber!)-\(trackText) - "
                : "\(trackText) - "
        } else {
            number = ""
        }
        let originalExtension = sanitizedExtension(
            track.originalExtension.isEmpty
                ? URL(fileURLWithPath: track.originalFilename).pathExtension
                : track.originalExtension
        )
        let base = number + sanitized(track.title, fallback: "Untitled")
        var filename = originalExtension.isEmpty
            ? base
            : "\(base).\(originalExtension)"
        let relativeKey = directory.path + "/" + filename.lowercased()
        if let existingHash = pathsByKey[relativeKey],
           existingHash != track.contentHash {
            let suffix = String(track.contentHash.prefix(8))
            filename = originalExtension.isEmpty
                ? "\(base) [\(suffix)]"
                : "\(base) [\(suffix)].\(originalExtension)"
        }
        pathsByKey[directory.path + "/" + filename.lowercased()] =
            track.contentHash
        let candidate = directory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: candidate.path),
           (try? fileMatches(candidate, track: track)) != true {
            let suffix = String(track.contentHash.prefix(8))
            let conflictName = originalExtension.isEmpty
                ? "\(base) [\(suffix)]"
                : "\(base) [\(suffix)].\(originalExtension)"
            return directory.appendingPathComponent(conflictName)
        }
        return candidate
    }

    private func sanitized(_ value: String, fallback: String) -> String {
        let replaced = value
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "꞉")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replaced.isEmpty, replaced != ".", replaced != ".." else {
            return fallback
        }
        return String(replaced.prefix(180))
    }

    private func sanitizedExtension(_ value: String) -> String {
        String(
            value.lowercased()
                .filter { $0.isLetter || $0.isNumber }
                .prefix(16)
        )
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return 0
        }
        return UInt64(size)
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576),
              !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
