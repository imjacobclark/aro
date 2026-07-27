import Foundation
import AroCommon

enum LibraryProfileKind: String, Codable, Sendable {
    case local
    case remote
}

struct LibraryProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: LibraryProfileKind
    var databasePath: String
    var mediaPath: String
    var managedMusicPath: String?
    var referencedMusicPaths: [String]
    var hubID: UUID?
    var baseURL: URL?
    var sharingEnabled: Bool
    var offlinePolicy: OfflineDownloadPolicy
    var storageLimitBytes: Int64?
    var createdAt: Date
    var lastActivatedAt: Date

    var isStoredOnThisMac: Bool {
        kind == .local
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case databasePath
        case mediaPath
        case managedMusicPath
        case referencedMusicPaths
        case hubID
        case baseURL
        case sharingEnabled
        case offlinePolicy
        case storageLimitBytes
        case createdAt
        case lastActivatedAt
    }

    init(
        id: UUID,
        name: String,
        kind: LibraryProfileKind,
        databasePath: String,
        mediaPath: String,
        managedMusicPath: String?,
        referencedMusicPaths: [String],
        hubID: UUID?,
        baseURL: URL?,
        sharingEnabled: Bool,
        offlinePolicy: OfflineDownloadPolicy,
        storageLimitBytes: Int64?,
        createdAt: Date,
        lastActivatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.databasePath = databasePath
        self.mediaPath = mediaPath
        self.managedMusicPath = managedMusicPath
        self.referencedMusicPaths = referencedMusicPaths
        self.hubID = hubID
        self.baseURL = baseURL
        self.sharingEnabled = sharingEnabled
        self.offlinePolicy = offlinePolicy
        self.storageLimitBytes = storageLimitBytes
        self.createdAt = createdAt
        self.lastActivatedAt = lastActivatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(LibraryProfileKind.self, forKey: .kind)
        databasePath = try values.decode(String.self, forKey: .databasePath)
        mediaPath = try values.decode(String.self, forKey: .mediaPath)
        managedMusicPath = try values.decodeIfPresent(
            String.self,
            forKey: .managedMusicPath
        )
        referencedMusicPaths = try values.decodeIfPresent(
            [String].self,
            forKey: .referencedMusicPaths
        ) ?? []
        hubID = try values.decodeIfPresent(UUID.self, forKey: .hubID)
        baseURL = try values.decodeIfPresent(URL.self, forKey: .baseURL)
        sharingEnabled = try values.decode(
            Bool.self,
            forKey: .sharingEnabled
        )
        offlinePolicy = try values.decode(
            OfflineDownloadPolicy.self,
            forKey: .offlinePolicy
        )
        storageLimitBytes = try values.decodeIfPresent(
            Int64.self,
            forKey: .storageLimitBytes
        )
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastActivatedAt = try values.decode(
            Date.self,
            forKey: .lastActivatedAt
        )
    }
}

struct LibraryProfileSnapshot: Codable, Sendable {
    var profiles: [LibraryProfile]
    var activeProfileID: UUID?
    var setupDismissed: Bool
}
