import Foundation

public enum AroSyncProtocol {
    public static let currentVersion: UInt16 = 5
}

public enum SyncReplicaMode: String, Codable, CaseIterable, Sendable {
    case onDemand
    case fullMirror
}

/// The user-facing policy for music that should remain available without the
/// library host. `SyncReplicaMode` remains on the wire for protocol v2
/// compatibility; new UI should use this type.
public enum OfflineDownloadPolicy: Hashable, Codable, Sendable {
    case streamOnly
    case stream
    case favourites
    case selectedAlbums(Set<String>)
    case fullLibrary

    public var keepsTemporaryDownloads: Bool {
        self == .stream
    }
}

public enum HubImportMode: String, Codable, CaseIterable, Sendable {
    case managed
    case referenced
}

public struct DiscoveredHub: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let host: String
    public let port: UInt16
    public let protocolVersion: UInt16
    public let pairingAvailable: Bool

    public init(
        id: UUID,
        name: String,
        host: String,
        port: UInt16,
        protocolVersion: UInt16,
        pairingAvailable: Bool
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.protocolVersion = protocolVersion
        self.pairingAvailable = pairingAvailable
    }
}

public struct AroHubInfo: Hashable, Codable, Sendable {
    public let hubID: UUID
    public let displayName: String
    public let protocolMin: UInt16
    public let protocolMax: UInt16
    public let pairingAvailable: Bool
    /// Whether this hub has an AcoustID key configured -- lets a client tell
    /// "identification is off because nobody's turned it on" apart from
    /// "nothing's queued right now". Never the key itself.
    public let identificationAvailable: Bool

    public init(
        hubID: UUID,
        displayName: String,
        protocolMin: UInt16,
        protocolMax: UInt16,
        pairingAvailable: Bool,
        identificationAvailable: Bool = false
    ) {
        self.hubID = hubID
        self.displayName = displayName
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.pairingAvailable = pairingAvailable
        self.identificationAvailable = identificationAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case hubID, displayName, protocolMin, protocolMax, pairingAvailable
        case identificationAvailable
    }

    /// Custom decode so a hub running an older build -- one that predates
    /// this field -- doesn't take down every `/v1/hub` call across the app
    /// (including the compatibility check every sync pass opens with) just
    /// because one new, non-essential field is missing from its response.
    /// Protocol fields added here should default rather than requiring a
    /// perfectly version-matched hub.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hubID = try container.decode(UUID.self, forKey: .hubID)
        displayName = try container.decode(String.self, forKey: .displayName)
        protocolMin = try container.decode(UInt16.self, forKey: .protocolMin)
        protocolMax = try container.decode(UInt16.self, forKey: .protocolMax)
        pairingAvailable = try container.decode(Bool.self, forKey: .pairingAvailable)
        identificationAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .identificationAvailable
        ) ?? false
    }
}

public struct HubDeviceCredential: Hashable, Codable, Sendable {
    public let deviceID: UUID
    public let credential: String

    public init(deviceID: UUID, credential: String) {
        self.deviceID = deviceID
        self.credential = credential
    }
}

public struct RemoteMedia: Hashable, Codable, Sendable {
    public let trackID: UUID
    public let contentHash: String
    public let byteCount: Int64
    public let downloadURL: URL

    public init(
        trackID: UUID,
        contentHash: String,
        byteCount: Int64,
        downloadURL: URL
    ) {
        self.trackID = trackID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.downloadURL = downloadURL
    }
}

public enum PlaybackMediaLocation: Hashable, Sendable {
    case local(URL)
    case remote(RemoteMedia)
}

public struct CachedBlob: Hashable, Sendable {
    public let contentHash: String
    public let byteCount: Int64
    public let lastAccessedAt: Date
    public let isPinned: Bool
    public let isQueued: Bool
    public let isCurrent: Bool

    public init(
        contentHash: String,
        byteCount: Int64,
        lastAccessedAt: Date,
        isPinned: Bool = false,
        isQueued: Bool = false,
        isCurrent: Bool = false
    ) {
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.lastAccessedAt = lastAccessedAt
        self.isPinned = isPinned
        self.isQueued = isQueued
        self.isCurrent = isCurrent
    }
}

public struct CacheEvictionPolicy: Sendable {
    public static let defaultLimitBytes: Int64 = 20 * 1_024 * 1_024 * 1_024

    public static func automaticLimitBytes(
        availableCapacity: Int64
    ) -> Int64 {
        min(
            defaultLimitBytes,
            max(1 * 1_024 * 1_024 * 1_024, availableCapacity / 10)
        )
    }

    public init() {}

    public func evictionCandidates(
        entries: [CachedBlob],
        limitBytes: Int64
    ) -> [CachedBlob] {
        var size = entries.reduce(Int64.zero) { $0 + $1.byteCount }
        guard size > limitBytes else { return [] }

        var selected: [CachedBlob] = []
        for entry in entries
            .filter({ !$0.isPinned && !$0.isQueued && !$0.isCurrent })
            .sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            selected.append(entry)
            size -= entry.byteCount
            if size <= limitBytes {
                break
            }
        }
        return selected
    }
}

public struct SyncFieldVersion: Hashable, Codable, Sendable {
    public let physicalMilliseconds: Int64
    public let logical: UInt32
    public let deviceID: UUID

    public init(
        physicalMilliseconds: Int64,
        logical: UInt32,
        deviceID: UUID
    ) {
        self.physicalMilliseconds = physicalMilliseconds
        self.logical = logical
        self.deviceID = deviceID
    }
}

extension SyncFieldVersion {
    enum CodingKeys: String, CodingKey {
        case physicalMilliseconds = "physicalMillis"
        case logical
        case deviceID
    }
}

extension SyncFieldVersion: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
            return lhs.physicalMilliseconds < rhs.physicalMilliseconds
        }
        if lhs.logical != rhs.logical {
            return lhs.logical < rhs.logical
        }
        return lhs.deviceID.uuidString < rhs.deviceID.uuidString
    }
}
