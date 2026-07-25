import Foundation

public struct AudioMetadata: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let genre: String?
    public let releaseYear: Int?
    public let artworkData: Data?
    public let duration: TimeInterval?
    public let properties: AudioFileProperties?

    public init(
        title: String?,
        artist: String?,
        album: String? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        artworkData: Data? = nil,
        duration: TimeInterval?,
        properties: AudioFileProperties? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.releaseYear = releaseYear
        self.artworkData = artworkData
        self.duration = duration
        self.properties = properties
    }
}

public struct ScanResult: Sendable {
    public let songs: [Song]
    public let skippedFileCount: Int

    public init(songs: [Song], skippedFileCount: Int) {
        self.songs = songs
        self.skippedFileCount = skippedFileCount
    }
}

public enum FolderScanState: Equatable, Sendable {
    case idle
    case scanning
    case warning(String)
}

public struct LibrarySummary: Equatable, Sendable {
    public let songCount: Int
    public let durationMinutes: Int
    public let fileSizeBytes: Int64

    public init(songs: [Song]) {
        songCount = songs.count
        durationMinutes = Int(songs.compactMap(\.duration).reduce(0, +) / 60)
        fileSizeBytes = songs.compactMap(\.fileSizeBytes).reduce(0, +)
    }

    public var formatted: String {
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

public extension Song {
    var formattedDuration: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
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

public extension AudioFileProperties {
    var formattedSampleRate: String? {
        guard let sampleRate, sampleRate > 0 else { return nil }
        let value = (sampleRate / 1_000).formatted(
            .number.precision(.fractionLength(0...1))
        )
        return "\(value) kHz"
    }
}
