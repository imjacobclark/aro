import SonoraCommon

protocol LegacyWatchedFolderStoring: Sendable {
    func load() -> [StoredWatchedFolder]
    func save(_ folders: [StoredWatchedFolder])
}
