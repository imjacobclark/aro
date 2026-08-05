import Foundation

public enum JSONValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct SyncOperation: Hashable, Codable, Sendable {
    public let operationID: UUID
    public let deviceID: UUID
    public let entityType: String
    public let entityID: String
    public let kind: String
    public let payload: JSONValue
    public let fieldVersions: [String: SyncFieldVersion]

    public init(
        operationID: UUID,
        deviceID: UUID,
        entityType: String,
        entityID: String,
        kind: String,
        payload: JSONValue,
        fieldVersions: [String: SyncFieldVersion]
    ) {
        self.operationID = operationID
        self.deviceID = deviceID
        self.entityType = entityType
        self.entityID = entityID
        self.kind = kind
        self.payload = payload
        self.fieldVersions = fieldVersions
    }
}

public struct SequencedSyncOperation: Hashable, Codable, Sendable {
    public let sequence: UInt64
    public let operationID: UUID
    public let deviceID: UUID
    public let entityType: String
    public let entityID: String
    public let kind: String
    public let payload: JSONValue
    public let fieldVersions: [String: SyncFieldVersion]

    public init(
        sequence: UInt64,
        operationID: UUID,
        deviceID: UUID,
        entityType: String,
        entityID: String,
        kind: String,
        payload: JSONValue,
        fieldVersions: [String: SyncFieldVersion]
    ) {
        self.sequence = sequence
        self.operationID = operationID
        self.deviceID = deviceID
        self.entityType = entityType
        self.entityID = entityID
        self.kind = kind
        self.payload = payload
        self.fieldVersions = fieldVersions
    }

    public var operation: SyncOperation {
        SyncOperation(
            operationID: operationID,
            deviceID: deviceID,
            entityType: entityType,
            entityID: entityID,
            kind: kind,
            payload: payload,
            fieldVersions: fieldVersions
        )
    }
}

public struct SyncExchangeRequest: Codable, Sendable {
    public let afterSequence: UInt64
    public let limit: UInt32
    public let operations: [SyncOperation]
    public let deviceReport: DeviceSyncReport?

    public init(
        afterSequence: UInt64,
        limit: UInt32 = 200,
        operations: [SyncOperation],
        deviceReport: DeviceSyncReport? = nil
    ) {
        self.afterSequence = afterSequence
        self.limit = limit
        self.operations = operations
        self.deviceReport = deviceReport
    }
}

public struct DeviceSyncReport: Codable, Sendable {
    public let offlineTrackCount: UInt64
    public let sources: [SourceHealthReport]

    public init(
        offlineTrackCount: UInt64,
        sources: [SourceHealthReport] = []
    ) {
        self.offlineTrackCount = offlineTrackCount
        self.sources = sources
    }
}

public struct SourceHealthReport: Hashable, Codable, Sendable {
    public let sourceID: UUID
    public let name: String
    public let mode: String
    public let available: Bool
    public let warning: String?
    public let songCount: UInt64?

    public init(
        sourceID: UUID,
        name: String,
        mode: String,
        available: Bool,
        warning: String? = nil,
        songCount: UInt64? = nil
    ) {
        self.sourceID = sourceID
        self.name = name
        self.mode = mode
        self.available = available
        self.warning = warning
        self.songCount = songCount
    }
}

public struct AroDeviceAccess: Codable, Sendable {
    public let deviceID: UUID
    public let name: String
    public let canContribute: Bool
}

public struct AroBlobStatus: Codable, Sendable {
    public let hash: String
    public let exists: Bool
    public let committedSize: UInt64
    public let uploadedSize: UInt64
}

public struct AroBlobCommitRequest: Codable, Sendable {
    public let hash: String
    public let size: UInt64

    public init(hash: String, size: UInt64) {
        self.hash = hash
        self.size = size
    }
}

/// Request body for `POST v1/identify` — the remote-hub equivalent of the local
/// control socket's `identify_tracks` command. Content hashes only, deliberately no
/// file path: a path on the calling device's filesystem is meaningless to a remote
/// hub, which resolves its own on-disk path from the hash.
public struct AroIdentifyTracksRequest: Codable, Sendable {
    public let contentHashes: [String]

    public init(contentHashes: [String]) {
        self.contentHashes = contentHashes
    }
}

public struct AroIdentifyTracksResponse: Codable, Sendable {
    public let queued: Int
    public let unresolved: [String]
}

public struct AroExportManifest: Codable, Sendable {
    public let schemaVersion: UInt16
    public let libraryName: String
    public let generatedAt: Date
    public let tracks: [AroExportTrack]

    public init(
        schemaVersion: UInt16,
        libraryName: String,
        generatedAt: Date,
        tracks: [AroExportTrack]
    ) {
        self.schemaVersion = schemaVersion
        self.libraryName = libraryName
        self.generatedAt = generatedAt
        self.tracks = tracks
    }
}

public struct AroExportTrack: Identifiable, Codable, Sendable {
    public let trackID: UUID
    public let contentHash: String
    public let byteCount: UInt64
    public let title: String
    public let artist: String
    public let album: String?
    public let trackNumber: UInt32?
    public let discNumber: UInt32?
    public let originalFilename: String
    public let originalExtension: String
    public let removedAt: Date?

    public var id: UUID { trackID }

    public init(
        trackID: UUID,
        contentHash: String,
        byteCount: UInt64,
        title: String,
        artist: String,
        album: String?,
        trackNumber: UInt32?,
        discNumber: UInt32?,
        originalFilename: String,
        originalExtension: String,
        removedAt: Date?
    ) {
        self.trackID = trackID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.originalFilename = originalFilename
        self.originalExtension = originalExtension
        self.removedAt = removedAt
    }
}

public struct SyncExchangeResponse: Codable, Sendable {
    public let accepted: [SequencedSyncOperation]
    public let changes: [SequencedSyncOperation]
    public let nextCursor: UInt64
    public let hasMore: Bool
}

public struct VersionedJSONValue: Hashable, Codable, Sendable {
    public let value: JSONValue
    public let timestamp: SyncFieldVersion

    public init(value: JSONValue, timestamp: SyncFieldVersion) {
        self.value = value
        self.timestamp = timestamp
    }
}

public struct SyncManifestEntry: Hashable, Codable, Sendable {
    public let localTrackID: String
    public let hubTrackID: UUID?
    public let contentHash: String?
    public let fields: [String: VersionedJSONValue]
    public let tombstoned: Bool

    public init(
        localTrackID: String,
        hubTrackID: UUID? = nil,
        contentHash: String?,
        fields: [String: VersionedJSONValue],
        tombstoned: Bool = false
    ) {
        self.localTrackID = localTrackID
        self.hubTrackID = hubTrackID
        self.contentHash = contentHash
        self.fields = fields
        self.tombstoned = tombstoned
    }
}

public struct JoinPreviewRequest: Codable, Sendable {
    public let deviceID: UUID
    public let manifest: [SyncManifestEntry]

    public init(deviceID: UUID, manifest: [SyncManifestEntry]) {
        self.deviceID = deviceID
        self.manifest = manifest
    }
}

public struct SyncFieldConflict: Hashable, Codable, Sendable {
    public let trackID: UUID
    public let field: String
    public let local: VersionedJSONValue
    public let hub: VersionedJSONValue

    public var resolutionKey: String {
        "\(trackID.uuidString.lowercased()):\(field)"
    }
}

public struct FirstJoinPreview: Codable, Sendable {
    public let previewID: UUID
    public let deduplicatedTracks: Int
    public let localOnlyTracks: Int
    public let hubOnlyTracks: Int
    public let conflicts: [SyncFieldConflict]
    public let requiredBytes: UInt64
}

public enum SyncConflictChoice: String, Codable, Sendable {
    case local
    case hub
}

public struct JoinCommitRequest: Codable, Sendable {
    public let previewID: UUID
    public let resolutions: [String: SyncConflictChoice]

    public init(
        previewID: UUID,
        resolutions: [String: SyncConflictChoice]
    ) {
        self.previewID = previewID
        self.resolutions = resolutions
    }
}

public enum SyncJobState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public enum PlaybackActivityState: String, Codable, Sendable {
    case playing
    case buffering
    case stopped
}

public struct PlaybackOutputSnapshot: Codable, Sendable {
    public let routeName: String?
    public let playbackMode: String?
    public let sampleRate: Double?
    public let bitDepth: UInt32?
    public let exclusive: Bool?
    public let wireless: Bool?

    public init(status: PlaybackOutputStatus) {
        routeName = status.deviceName
        playbackMode = status.mode.rawValue
        sampleRate = status.sampleRate
        bitDepth = status.bitDepth.map(UInt32.init)
        exclusive = status.isExclusive
        wireless = status.transport.isWireless
    }
}

/// Lightweight server-owned catalog data used by streaming/on-demand clients.
/// Artwork remains a content-addressed reference and is fetched lazily.
public struct CatalogTrack: Identifiable, Codable, Sendable, Hashable {
    public let trackID: UUID
    public let sourceID: UUID?
    public let sourceName: String?
    public let contentHash: String?
    public let title: String
    public let artist: String?
    public let album: String?
    public let genre: String?
    public let releaseYear: UInt32?
    public let durationSeconds: Double?
    public let byteCount: UInt64?
    public let codec: String?
    public let sampleRate: Double?
    public let bitDepth: UInt32?
    public let channelCount: UInt32?
    public let bitrate: Double?
    public let integratedLufs: Double?
    public let peakAmplitude: Double?
    public let loudnessAnalyzedAt: Double?
    public let loudnessAlgorithmVersion: UInt32?
    public let trackNumber: UInt32?
    public let discNumber: UInt32?
    public let artworkHash: String?
    /// Optional for decoding catalogue snapshots written by pre-favourite builds.
    public let favourite: Bool?
    public let available: Bool

    public var id: UUID { trackID }
}

public struct CatalogPage: Codable, Sendable, Hashable {
    public let tracks: [CatalogTrack]
    public let nextCursor: String?
    public let revision: UInt64

    public init(
        tracks: [CatalogTrack],
        nextCursor: String?,
        revision: UInt64
    ) {
        self.tracks = tracks
        self.nextCursor = nextCursor
        self.revision = revision
    }
}

public struct PlaybackActivitySnapshot: Codable, Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public let contentHash: String
    public let state: PlaybackActivityState
    public let positionSeconds: Double
    public let durationSeconds: Double?
    public let bufferedFraction: Double?
    public let observedAt: Date
    public let startedAt: Date
    public let completed: Bool
    public let output: PlaybackOutputSnapshot?

    public init(
        sessionID: UUID,
        revision: UInt64,
        contentHash: String,
        state: PlaybackActivityState,
        positionSeconds: Double,
        durationSeconds: Double?,
        bufferedFraction: Double?,
        observedAt: Date,
        startedAt: Date,
        completed: Bool,
        output: PlaybackOutputSnapshot?
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.contentHash = contentHash
        self.state = state
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.bufferedFraction = bufferedFraction
        self.observedAt = observedAt
        self.startedAt = startedAt
        self.completed = completed
        self.output = output
    }
}

public struct RemoteSyncJob: Codable, Sendable {
    public let jobID: UUID
    public let kind: String
    public let state: SyncJobState
    public let completedUnits: UInt64
    public let totalUnits: UInt64
    public let error: String?
}

/// Where a cover offered by the hub's artwork picker came from, so the UI can group
/// candidates instead of presenting one undifferentiated wall of images.
public enum RemoteArtworkOrigin: String, Codable, Sendable {
    /// A pressing of the album this track is currently filed under. MusicBrainz often
    /// carries one album as many releases, and the Cover Art Archive is populated per
    /// release, so these are genuinely different scans rather than duplicates.
    case thisAlbum = "this_album"
    /// A different album by the same artist.
    case artistCatalogue = "artist_catalogue"
}

/// One cover the hub found for a track. `thumbnail` is already cached as a hub blob and is
/// what the picker renders; `fullImageURL` is fetched only if this candidate is chosen, so
/// browsing a discography never pulls full-resolution art for images nobody picks.
public struct RemoteArtworkCandidate: Codable, Sendable, Hashable {
    public let thumbnail: String
    public let fullImageURL: String
    public let origin: RemoteArtworkOrigin
    public let album: String?
    public let releaseID: String?
    public let releaseGroupID: String?
    public let isFront: Bool
}

public struct RemoteArtworkResolveRequest: Codable, Sendable {
    public let imageURL: String

    public init(imageURL: String) {
        self.imageURL = imageURL
    }
}

public struct RemoteArtworkResolveResponse: Codable, Sendable {
    public let blob: String
}

/// The quality a track is delivered at. `original` is the untouched source file; every
/// other tier is Opus, which is markedly better than AAC or MP3 at these bitrates and which
/// the playback engine already decodes.
///
/// A losslessly-ripped library is enormous next to what a phone on a mobile connection
/// needs — roughly 24 MB a track against a little over 2 MB at `saver`.
public enum StreamQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case high
    case balanced
    case saver
    case minimum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .high: "High"
        case .balanced: "Balanced"
        case .saver: "Saver"
        case .minimum: "Minimum"
        }
    }

    /// `nil` for `original`, which is never re-encoded.
    public var kilobitsPerSecond: Int? {
        switch self {
        case .original: nil
        case .high: 192
        case .balanced: 128
        case .saver: 96
        case .minimum: 64
        }
    }

    public var detail: String {
        switch self {
        case .original: "Bit-perfect. Largest files, no conversion needed."
        case .high: "192 kbps Opus. Transparent for almost any listening."
        case .balanced: "128 kbps Opus. Excellent quality at a third of the size."
        case .saver: "96 kbps Opus. Good quality, roughly a tenth of the size."
        case .minimum: "64 kbps Opus. For tight mobile connections."
        }
    }
}

/// What converting the library to a given quality would cost, quoted by the hub that would
/// do the work. Hubs differ by more than an order of magnitude, so this is measured on the
/// machine itself rather than estimated from a constant.
public struct RemoteTranscodePlan: Codable, Sendable {
    public let quality: String
    public let tracksTotal: UInt64
    public let tracksPending: UInt64
    public let pendingAudioSeconds: Double
    public let estimatedSeconds: Double
    public let estimatedBytes: UInt64
    public let concurrency: Int
}

public struct RemoteTranscodeStartRequest: Codable, Sendable {
    public let quality: String

    public init(quality: String) {
        self.quality = quality
    }
}

public struct RemoteTranscodeCleanupRequest: Codable, Sendable {
    /// The quality to keep; every other cached encode is removed.
    public let keep: String

    public init(keep: String) {
        self.keep = keep
    }
}

public struct RemoteTranscodeCleanupResponse: Codable, Sendable {
    public let removed: UInt64
    public let freedBytes: UInt64
}

public struct RemoteTranscodeUsage: Codable, Sendable, Identifiable {
    public let quality: String
    public let tracks: UInt64
    public let bytes: UInt64

    public var id: String { quality }
}

public struct RemoteArtworkDiscoverRequest: Codable, Sendable {
    public let contentHash: String

    public init(contentHash: String) {
        self.contentHash = contentHash
    }
}

/// How one metadata field compares between Aro's library and the file on disk.
public enum MetadataFieldVerdict: String, Codable, Sendable {
    case agrees
    case differs
    /// Aro knows a value the file doesn't carry.
    case missingInFile = "missing_in_file"
    /// The file carries a value Aro doesn't hold.
    case missingInAro = "missing_in_aro"
    case absent

    /// Whether this is worth drawing attention to. Agreement and mutual absence are the
    /// quiet majority; showing them as loudly as a real difference buries the difference.
    public var isDifference: Bool {
        switch self {
        case .differs, .missingInFile, .missingInAro: true
        case .agrees, .absent: false
        }
    }
}

public struct RemoteMetadataFieldDelta: Codable, Sendable, Identifiable {
    public let field: String
    public let aro: String?
    public let file: String?
    public let verdict: MetadataFieldVerdict

    public var id: String { field }

    /// Title-cased field name for display — the wire uses snake_case keys.
    public var label: String {
        field
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Where a track's audio actually is.
///
/// Three states rather than a boolean because they mean different things: Aro holding a
/// copy keeps the track playable, while only a reachable original can have corrected tags
/// written into it.
public enum RemoteTrackAvailability: String, Codable, Sendable {
    case originalAndCopy = "original_and_copy"
    case originalOnly = "original_only"
    case copyOnly = "copy_only"
    case missing

    public var label: String {
        switch self {
        case .originalAndCopy: "Original file and Aro copy"
        case .originalOnly: "Original file only"
        case .copyOnly: "Aro copy only"
        case .missing: "No file available"
        }
    }

    public var detail: String {
        switch self {
        case .originalAndCopy: "Your file is reachable and Aro holds its own copy."
        case .originalOnly: "Only your original file — if it goes, the track goes."
        case .copyOnly: "Aro's copy plays, but your original isn't reachable from the library."
        case .missing: "Catalogued, but nothing can play it."
        }
    }
}

public struct RemoteTrackMetadataDelta: Codable, Sendable, Identifiable {
    public let contentHash: String
    public let trackID: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let availability: RemoteTrackAvailability
    /// Only a reachable original can be written to.
    public let writable: Bool
    public let originalPath: String?
    public let fields: [RemoteMetadataFieldDelta]
    public let differenceCount: Int

    public var id: String { contentHash }

    public var differingFields: [RemoteMetadataFieldDelta] {
        fields.filter(\.verdict.isDifference)
    }
}
