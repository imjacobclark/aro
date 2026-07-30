import Foundation

public protocol AudioMetadataReading: Sendable {
    func metadata(for url: URL) async -> AudioMetadata?
}

public protocol AudioScanning: Sendable {
    func scan(folder: URL) async -> ScanResult
}

public protocol ContentHashCaching: Sendable {
    func cachedContentHash(path: String, fileSize: Int64, modificationDate: Date) -> String?
}

public protocol FolderMonitoring: AnyObject, Sendable {
    func stop()
}

public protocol FolderMonitorCreating: Sendable {
    func makeMonitor(
        for url: URL,
        handler: @escaping @Sendable () -> Void
    ) -> (any FolderMonitoring)?
}

public protocol TrackStateRepository: Sendable {
    func setHidden(trackID: UUID, hidden: Bool) throws
    func setFavourite(trackID: UUID, favourite: Bool) throws
    func tombstone(trackID: UUID) throws
}
