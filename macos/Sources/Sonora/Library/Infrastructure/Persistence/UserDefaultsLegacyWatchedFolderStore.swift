import SonoraCommon

import Foundation

struct UserDefaultsLegacyWatchedFolderStore:
    LegacyWatchedFolderStoring,
    @unchecked Sendable
{
    private static let key = "watchedFolders.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [StoredWatchedFolder] {
        guard let data = defaults.data(forKey: Self.key) else {
            return []
        }
        return (try? JSONDecoder().decode(
            [StoredWatchedFolder].self,
            from: data
        )) ?? []
    }

    func save(_ folders: [StoredWatchedFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
