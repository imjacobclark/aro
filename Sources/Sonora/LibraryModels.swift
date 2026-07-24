import Foundation

enum Destination: Hashable {
    case songs
    case stats
    case libraryHealth
    case folder(UUID)
}

struct WatchedFolder: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let displayName: String
    let bookmarkData: Data?
    var isAccessible: Bool
    var didStartSecurityScope: Bool
}

struct Song: Identifiable, Hashable, Sendable {
    let libraryID: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String?
    let genre: String?
    let releaseYear: Int?
    let duration: TimeInterval?
    let fileSizeBytes: Int64?
    let audioProperties: AudioFileProperties?
    let fileFingerprint: AudioFileFingerprint?
    var loudness: LoudnessAnalysis?

    init(
        libraryID: UUID = UUID(),
        url: URL,
        title: String,
        artist: String,
        album: String? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        duration: TimeInterval?,
        fileSizeBytes: Int64? = nil,
        audioProperties: AudioFileProperties? = nil,
        fileFingerprint: AudioFileFingerprint? = nil,
        loudness: LoudnessAnalysis? = nil
    ) {
        self.libraryID = libraryID
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.releaseYear = releaseYear
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.audioProperties = audioProperties
        self.fileFingerprint = fileFingerprint
        self.loudness = loudness
    }

    var id: String {
        libraryID.uuidString
    }

    var formattedDuration: String {
        guard let duration, duration.isFinite, duration >= 0 else {
            return "—"
        }

        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct AudioFileFingerprint: Hashable, Codable, Sendable {
    let standardizedPath: String
    let fileSizeBytes: Int64
    let modificationDate: Date
    let contentHash: String?

    init(
        standardizedPath: String,
        fileSizeBytes: Int64,
        modificationDate: Date,
        contentHash: String? = nil
    ) {
        self.standardizedPath = standardizedPath
        self.fileSizeBytes = fileSizeBytes
        self.modificationDate = modificationDate
        self.contentHash = contentHash
    }

    var cacheKey: String {
        contentHash
            ?? "\(standardizedPath)|\(fileSizeBytes)|\(modificationDate.timeIntervalSince1970)"
    }
}

struct AudioFileProperties: Hashable, Codable, Sendable {
    let codec: String
    let sampleRate: Double?
    let bitDepth: Int?
    let channelCount: Int?
    let bitrate: Double?

    var formattedSampleRate: String? {
        guard let sampleRate, sampleRate > 0 else {
            return nil
        }

        let kilohertz = sampleRate / 1_000
        let value = kilohertz.formatted(
            .number.precision(.fractionLength(0...1))
        )
        return "\(value) kHz"
    }
}

struct LoudnessAnalysis: Hashable, Codable, Sendable {
    static let algorithmVersion = 1

    let integratedLUFS: Double
    let peakAmplitude: Double
    let analyzedAt: Date
    let algorithmVersion: Int

    init(
        integratedLUFS: Double,
        peakAmplitude: Double,
        analyzedAt: Date = Date(),
        algorithmVersion: Int = Self.algorithmVersion
    ) {
        self.integratedLUFS = integratedLUFS
        self.peakAmplitude = peakAmplitude
        self.analyzedAt = analyzedAt
        self.algorithmVersion = algorithmVersion
    }

    func safeGainDecibels(
        targetLUFS: Double,
        peakCeilingDBFS: Double = -1
    ) -> Double {
        let targetGain = targetLUFS - integratedLUFS
        guard peakAmplitude > 0 else {
            return min(targetGain, 0)
        }

        let peakDBFS = 20 * log10(peakAmplitude)
        return min(targetGain, peakCeilingDBFS - peakDBFS)
    }
}

struct LibrarySummary: Equatable {
    let songCount: Int
    let durationMinutes: Int
    let fileSizeBytes: Int64

    init(songs: [Song]) {
        songCount = songs.count
        durationMinutes = Int(
            songs.compactMap(\.duration).reduce(0, +) / 60
        )
        fileSizeBytes = songs.compactMap(\.fileSizeBytes).reduce(0, +)
    }

    var formatted: String {
        "\(songCount) \(songCount == 1 ? "song" : "songs"), "
            + "\(durationMinutes) mins, \(formattedFileSize)"
    }

    private var formattedFileSize: String {
        let unit: String
        let divisor: Double

        if fileSizeBytes >= 1_000_000_000_000 {
            unit = "tb"
            divisor = 1_000_000_000_000
        } else if fileSizeBytes >= 1_000_000_000 {
            unit = "gb"
            divisor = 1_000_000_000
        } else {
            unit = "mb"
            divisor = 1_000_000
        }

        let value = Double(fileSizeBytes) / divisor
        let formattedValue = value.formatted(
            .number.precision(.fractionLength(0...1))
        )
        return "\(formattedValue) \(unit)"
    }
}

enum FolderScanState: Equatable {
    case idle
    case scanning
    case warning(String)
}

struct AudioMetadata: Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let genre: String?
    let releaseYear: Int?
    let duration: TimeInterval?
    let properties: AudioFileProperties?

    init(
        title: String?,
        artist: String?,
        album: String? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        duration: TimeInterval?,
        properties: AudioFileProperties? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.releaseYear = releaseYear
        self.duration = duration
        self.properties = properties
    }
}

struct ScanResult: Sendable {
    let songs: [Song]
    let skippedFileCount: Int
}

enum SongLibrary {
    static func aggregate(_ songsByFolder: [UUID: [Song]]) -> [Song] {
        deduplicated(songsByFolder.values.flatMap { $0 })
    }

    static func deduplicated(_ songs: [Song]) -> [Song] {
        var uniqueSongs: [String: Song] = [:]

        for song in songs {
            if let current = uniqueSongs[song.id] {
                if song.url.path.localizedStandardCompare(current.url.path)
                    == .orderedAscending {
                    uniqueSongs[song.id] = song
                }
            } else {
                uniqueSongs[song.id] = song
            }
        }

        return sorted(Array(uniqueSongs.values))
    }

    static func sorted(_ songs: [Song]) -> [Song] {
        songs.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }

            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame {
                return artistOrder == .orderedAscending
            }

            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}
