import Foundation

public struct LoudnessAnalysis: Hashable, Codable, Sendable {
    public static let algorithmVersion = 1

    public let integratedLUFS: Double
    public let peakAmplitude: Double
    public let analyzedAt: Date
    public let algorithmVersion: Int

    public init(
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

    public func safeGainDecibels(
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

public struct AudioFileFingerprint: Hashable, Codable, Sendable {
    public let standardizedPath: String
    public let fileSizeBytes: Int64
    public let modificationDate: Date
    public let contentHash: String?

    public init(
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

    public var cacheKey: String {
        contentHash
            ?? "\(standardizedPath)|\(fileSizeBytes)|\(modificationDate.timeIntervalSince1970)"
    }
}

public struct AudioFileProperties: Hashable, Codable, Sendable {
    public let codec: String
    public let sampleRate: Double?
    public let bitDepth: Int?
    public let channelCount: Int?
    public let bitrate: Double?

    public init(
        codec: String,
        sampleRate: Double?,
        bitDepth: Int?,
        channelCount: Int?,
        bitrate: Double?
    ) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.bitrate = bitrate
    }
}

public struct Song: Identifiable, Hashable, Sendable {
    public let libraryID: UUID
    public let url: URL
    public let title: String
    public let artist: String
    public let album: String?
    public let genre: String?
    public let releaseYear: Int?
    public let artworkData: Data?
    public let duration: TimeInterval?
    public let fileSizeBytes: Int64?
    public let audioProperties: AudioFileProperties?
    public let fileFingerprint: AudioFileFingerprint?
    public var loudness: LoudnessAnalysis?

    public init(
        libraryID: UUID = UUID(),
        url: URL,
        title: String,
        artist: String,
        album: String? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        artworkData: Data? = nil,
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
        self.artworkData = artworkData
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.audioProperties = audioProperties
        self.fileFingerprint = fileFingerprint
        self.loudness = loudness
    }

    public var id: String {
        libraryID.uuidString
    }

    public func replacingURL(_ url: URL) -> Song {
        Song(
            libraryID: libraryID,
            url: url,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            releaseYear: releaseYear,
            artworkData: artworkData,
            duration: duration,
            fileSizeBytes: fileSizeBytes,
            audioProperties: audioProperties,
            fileFingerprint: fileFingerprint,
            loudness: loudness
        )
    }
}

public enum SongLibrary {
    public static func aggregate(
        _ songsByFolder: [UUID: [Song]]
    ) -> [Song] {
        deduplicated(songsByFolder.values.flatMap { $0 })
    }

    public static func deduplicated(_ songs: [Song]) -> [Song] {
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

    public static func sorted(_ songs: [Song]) -> [Song] {
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
