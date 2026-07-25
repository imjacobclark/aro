import SonoraCommon

import Foundation

struct WatchedFolder: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let displayName: String
    let bookmarkData: Data?
    var isAccessible: Bool
    var didStartSecurityScope: Bool
}
