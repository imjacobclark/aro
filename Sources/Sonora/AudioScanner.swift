import AVFoundation
import CryptoKit
import Foundation
import SFBAudioEngine
import UniformTypeIdentifiers

protocol AudioMetadataReading: Sendable {
    func metadata(for url: URL) async -> AudioMetadata?
}

protocol AudioFileRecognizing: Sendable {
    func isAudioFile(at url: URL, resourceType: UTType?) -> Bool
}

struct SystemAudioFileRecognizer: AudioFileRecognizing {
    func isAudioFile(at url: URL, resourceType: UTType?) -> Bool {
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "flac", "m4a", "mp3",
            "oga", "ogg", "wav", "wave"
        ]
        let extensionType = UTType(filenameExtension: url.pathExtension)
        return supportedExtensions.contains(url.pathExtension.lowercased())
            || resourceType?.conforms(to: .audio) == true
            || extensionType?.conforms(to: .audio) == true
    }
}

struct SFBAudioMetadataReader: AudioMetadataReading, @unchecked Sendable {
    func metadata(for url: URL) async -> AudioMetadata? {
        do {
            let file = try SFBAudioEngine.AudioFile(
                readingPropertiesAndMetadataFrom: url
            )
            let properties = file.properties
            return AudioMetadata(
                title: file.metadata.title,
                artist: file.metadata.artist,
                album: file.metadata.albumTitle,
                genre: file.metadata.genre,
                releaseYear: file.metadata.releaseDate.flatMap {
                    Int($0.prefix(4))
                },
                duration: properties.duration,
                properties: AudioFileProperties(
                    codec: properties.formatName ?? url.pathExtension.uppercased(),
                    sampleRate: properties.sampleRate,
                    bitDepth: properties.bitDepth,
                    channelCount: properties.channelCount.map(Int.init),
                    bitrate: properties.bitrate
                )
            )
        } catch {
            return nil
        }
    }
}

struct AVFoundationMetadataReader: AudioMetadataReading {
    func metadata(for url: URL) async -> AudioMetadata? {
        let asset = AVURLAsset(url: url)

        do {
            guard try await asset.load(.isPlayable) else {
                return nil
            }

            async let duration = asset.load(.duration)
            async let commonMetadata = asset.load(.commonMetadata)

            let loadedDuration = try await duration
            let loadedMetadata = try await commonMetadata

            let title = await stringValue(
                for: .commonIdentifierTitle,
                in: loadedMetadata
            )
            let artist = await stringValue(
                for: .commonIdentifierArtist,
                in: loadedMetadata
            )

            return AudioMetadata(
                title: title,
                artist: artist,
                album: nil,
                genre: nil,
                releaseYear: nil,
                duration: loadedDuration.isNumeric ? loadedDuration.seconds : nil,
                properties: nil
            )
        } catch {
            return nil
        }
    }

    private func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        let item = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: identifier
        ).first

        guard let item else {
            return nil
        }

        let value = try? await item.load(.stringValue)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct AudioScanner: Sendable {
    private let metadataReader: any AudioMetadataReading
    private let fileRecognizer: any AudioFileRecognizing
    private let maximumConcurrentReads: Int
    private let contentHashCache: LibraryDatabase?

    init(
        metadataReader: any AudioMetadataReading = SFBAudioMetadataReader(),
        fileRecognizer: any AudioFileRecognizing = SystemAudioFileRecognizer(),
        maximumConcurrentReads: Int = 8,
        contentHashCache: LibraryDatabase? = .shared
    ) {
        self.metadataReader = metadataReader
        self.fileRecognizer = fileRecognizer
        self.maximumConcurrentReads = max(1, maximumConcurrentReads)
        self.contentHashCache = contentHashCache
    }

    func scan(folder: URL) async -> ScanResult {
        let discovery = Self.discoverAudioFiles(
            in: folder,
            fileRecognizer: fileRecognizer
        )
        let candidates = discovery.urls
        guard !Task.isCancelled else {
            return ScanResult(songs: [], skippedFileCount: 0)
        }

        var songs: [Song] = []
        var skippedFileCount = discovery.errorCount
        var iterator = candidates.makeIterator()

        await withTaskGroup(of: Song?.self) { group in
            for _ in 0..<min(maximumConcurrentReads, candidates.count) {
                guard let url = iterator.next() else {
                    break
                }
                addMetadataTask(for: url, to: &group)
            }

            while let song = await group.next() {
                if let song {
                    songs.append(song)
                } else {
                    skippedFileCount += 1
                }

                guard !Task.isCancelled, let url = iterator.next() else {
                    continue
                }
                addMetadataTask(for: url, to: &group)
            }
        }

        return ScanResult(
            songs: SongLibrary.sorted(songs),
            skippedFileCount: skippedFileCount
        )
    }

    private func addMetadataTask(
        for url: URL,
        to group: inout TaskGroup<Song?>
    ) {
        let metadataReader = metadataReader
        let contentHashCache = contentHashCache
        group.addTask {
            guard !Task.isCancelled,
                  let metadata = await metadataReader.metadata(for: url) else {
                return nil
            }

            let fallbackTitle = url.deletingPathExtension().lastPathComponent
            let resourceValues = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let fileSizeBytes = resourceValues?.fileSize.map(Int64.init)
            let fingerprint = fileSizeBytes.flatMap { fileSize in
                resourceValues?.contentModificationDate.map {
                    let standardizedPath = url.standardizedFileURL.path
                    let contentHash = contentHashCache?.cachedContentHash(
                        path: standardizedPath,
                        fileSize: fileSize,
                        modificationDate: $0
                    ) ?? Self.contentHash(for: url)
                    return AudioFileFingerprint(
                        standardizedPath: standardizedPath,
                        fileSizeBytes: fileSize,
                        modificationDate: $0,
                        contentHash: contentHash
                    )
                }
            }
            return Song(
                url: url,
                title: metadata.title?.nilIfEmpty ?? fallbackTitle,
                artist: metadata.artist?.nilIfEmpty ?? "—",
                album: metadata.album?.nilIfEmpty,
                genre: metadata.genre?.nilIfEmpty,
                releaseYear: metadata.releaseYear,
                duration: metadata.duration,
                fileSizeBytes: fileSizeBytes,
                audioProperties: metadata.properties,
                fileFingerprint: fingerprint
            )
        }
    }

    nonisolated private static func contentHash(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty {
                guard !Task.isCancelled else {
                    return nil
                }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        } catch {
            return nil
        }
    }

    nonisolated private static func discoverAudioFiles(
        in folder: URL,
        fileRecognizer: any AudioFileRecognizing
    ) -> (urls: [URL], errorCount: Int) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants
        ]
        let errorCounter = ScanErrorCounter()

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in
                errorCounter.increment()
                return true
            }
        ) else {
            return ([], 1)
        }

        var audioFiles: [URL] = []

        for case let url as URL in enumerator {
            guard !Task.isCancelled,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }

            let resourceType = try? url.resourceValues(
                forKeys: [.contentTypeKey]
            ).contentType
            guard fileRecognizer.isAudioFile(
                at: url,
                resourceType: resourceType
            ) else {
                continue
            }

            audioFiles.append(url.resolvingSymlinksInPath().standardizedFileURL)
        }

        return (audioFiles, errorCounter.value)
    }
}

private final class ScanErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
