import Foundation

public struct LoudnessAnalysis: Hashable, Codable, Sendable {
    /// Legacy macOS ReplayGain-derived measurement used for local files.
    public static let algorithmVersion = 1
    /// Authoritative BS.1770 measurement produced by an Aro hub.
    public static let remoteAlgorithmVersion = 2

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
    public var url: URL
    public let title: String
    public let artist: String
    public let album: String?
    public let genre: String?
    public let releaseYear: Int?
    /// Position within the release medium, supplied by file tags or authoritative
    /// MusicBrainz group matching. Album views use this rather than title order.
    public let trackNumber: Int?
    /// One-based release medium/disc position. `nil` is treated as disc one when a
    /// track number is present.
    public let discNumber: Int?
    public let artworkData: Data?
    public let duration: TimeInterval?
    public let fileSizeBytes: Int64?
    public let audioProperties: AudioFileProperties?
    public let fileFingerprint: AudioFileFingerprint?
    /// The file's content hash, independent of `fileFingerprint`. `fileFingerprint`
    /// is `nil` unless *both* file size and modification date resolved (it exists
    /// for change-detection, which genuinely needs all three); callers that only need
    /// the hash — e.g. addressing a file for background identification — shouldn't
    /// lose it just because one of those two lookups failed.
    public let contentHash: String?
    public let isFavourite: Bool
    public var loudness: LoudnessAnalysis?
    /// MusicBrainz's own curated genre subset for this track, from background AcoustID/
    /// MusicBrainz identification (see `aro_track_id::musicbrainz::canonicalize_tags`
    /// server-side) — distinct from `genre`, which is the file's own single ID3-style tag.
    /// Empty until identification has run and found matching data.
    public let musicbrainzGenres: [String]
    /// Up to 2 canonical mood tags (e.g. "relaxed", "energetic") derived server-side from
    /// MusicBrainz folksonomy tags — drives auto-generated mood playlists. Empty until
    /// identification has run and found a matching mood.
    public let moodTags: [String]

    public init(
        libraryID: UUID = UUID(),
        url: URL,
        title: String,
        artist: String,
        album: String? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        artworkData: Data? = nil,
        duration: TimeInterval?,
        fileSizeBytes: Int64? = nil,
        audioProperties: AudioFileProperties? = nil,
        fileFingerprint: AudioFileFingerprint? = nil,
        contentHash: String? = nil,
        isFavourite: Bool = false,
        loudness: LoudnessAnalysis? = nil,
        musicbrainzGenres: [String] = [],
        moodTags: [String] = []
    ) {
        self.libraryID = libraryID
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.releaseYear = releaseYear
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artworkData = artworkData
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.audioProperties = audioProperties
        self.fileFingerprint = fileFingerprint
        self.contentHash = contentHash ?? fileFingerprint?.contentHash
        self.isFavourite = isFavourite
        self.loudness = loudness
        self.musicbrainzGenres = musicbrainzGenres
        self.moodTags = moodTags
    }

    public var id: String {
        libraryID.uuidString
    }

    /// `Song` values flow through SwiftUI collection inputs. Artwork is often a
    /// large, album-repeated blob, so letting synthesized equality compare it
    /// turns an otherwise cheap view diff into repeated multi-megabyte memcmp
    /// work on the main thread. Artwork is intentionally excluded from the
    /// catalog equality contract; all metadata which affects rows, grouping,
    /// playback, and sorting remains part of it.
    public static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.libraryID == rhs.libraryID
            && lhs.url == rhs.url
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.genre == rhs.genre
            && lhs.releaseYear == rhs.releaseYear
            && lhs.trackNumber == rhs.trackNumber
            && lhs.discNumber == rhs.discNumber
            && lhs.duration == rhs.duration
            && lhs.fileSizeBytes == rhs.fileSizeBytes
            && lhs.audioProperties == rhs.audioProperties
            && lhs.fileFingerprint == rhs.fileFingerprint
            && lhs.contentHash == rhs.contentHash
            && lhs.isFavourite == rhs.isFavourite
            && lhs.loudness == rhs.loudness
            && lhs.musicbrainzGenres == rhs.musicbrainzGenres
            && lhs.moodTags == rhs.moodTags
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(libraryID)
        hasher.combine(url)
        hasher.combine(title)
        hasher.combine(artist)
        hasher.combine(album)
        hasher.combine(genre)
        hasher.combine(releaseYear)
        hasher.combine(trackNumber)
        hasher.combine(discNumber)
        hasher.combine(duration)
        hasher.combine(fileSizeBytes)
        hasher.combine(audioProperties)
        hasher.combine(fileFingerprint)
        hasher.combine(contentHash)
        hasher.combine(isFavourite)
        hasher.combine(loudness)
        hasher.combine(musicbrainzGenres)
        hasher.combine(moodTags)
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
            trackNumber: trackNumber,
            discNumber: discNumber,
            artworkData: artworkData,
            duration: duration,
            fileSizeBytes: fileSizeBytes,
            audioProperties: audioProperties,
            fileFingerprint: fileFingerprint,
            contentHash: contentHash,
            isFavourite: isFavourite,
            loudness: loudness,
            musicbrainzGenres: musicbrainzGenres,
            moodTags: moodTags
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

    /// Catalog order for tracks that share an album. Numbered releases are ordered
    /// by medium then track; unnumbered tracks retain the stable title order used by
    /// the general library.
    public static func albumSorted(_ songs: [Song]) -> [Song] {
        songs.sorted {
            switch ($0.trackNumber, $1.trackNumber) {
            case let (.some(leftTrack), .some(rightTrack)):
                let leftDisc = $0.discNumber ?? 1
                let rightDisc = $1.discNumber ?? 1
                if leftDisc != rightDisc { return leftDisc < rightDisc }
                if leftTrack != rightTrack { return leftTrack < rightTrack }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }

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
