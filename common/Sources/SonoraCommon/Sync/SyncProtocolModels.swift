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

    public init(
        afterSequence: UInt64,
        limit: UInt32 = 200,
        operations: [SyncOperation]
    ) {
        self.afterSequence = afterSequence
        self.limit = limit
        self.operations = operations
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

public struct RemoteSyncJob: Codable, Sendable {
    public let jobID: UUID
    public let kind: String
    public let state: SyncJobState
    public let completedUnits: UInt64
    public let totalUnits: UInt64
    public let error: String?
}
