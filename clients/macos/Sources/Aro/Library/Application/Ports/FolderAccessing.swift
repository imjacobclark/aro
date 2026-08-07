import AroCommon

import Foundation

struct ResolvedFolderAccess: Sendable {
    let url: URL
    let bookmarkData: Data?
    let didStartSecurityScope: Bool
}

protocol FolderAccessing: Sendable {
    func normalizedURL(_ url: URL) -> URL
    func bookmarkData(for url: URL) -> Data?
    func beginAccessing(_ url: URL) -> Bool
    func endAccessing(_ url: URL)
    func isAccessibleDirectory(_ url: URL) -> Bool
    func resolve(path: String, bookmarkData: Data?) -> ResolvedFolderAccess
}
