import SonoraCommon

import Foundation

struct SecurityScopedFolderAccess: FolderAccessing {
    func normalizedURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func beginAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func endAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func isAccessibleDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    func resolve(
        path: String,
        bookmarkData: Data?
    ) -> ResolvedFolderAccess {
        var bookmarkIsStale = false
        let bookmarkedURL = bookmarkData.flatMap {
            try? URL(
                resolvingBookmarkData: $0,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        }
        let url = normalizedURL(
            bookmarkedURL ?? URL(fileURLWithPath: path)
        )
        return ResolvedFolderAccess(
            url: url,
            bookmarkData: bookmarkIsStale
                ? self.bookmarkData(for: url)
                : bookmarkData,
            didStartSecurityScope: beginAccessing(url)
        )
    }
}
