import SonoraCommon

import Foundation

struct StoredWatchedFolder: Codable, Sendable {
    let id: UUID
    let displayName: String
    let path: String
    let bookmarkData: Data?
}
