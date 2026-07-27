import Foundation

public protocol RemoteMediaDownloading: Sendable {
    func download(_ media: RemoteMedia) async throws -> URL
}

public protocol MediaHashVerifying: Sendable {
    func verify(file: URL, expectedSHA256: String) async throws
}

public enum PrepareSongError: LocalizedError, Sendable {
    case missingLocalFile

    public var errorDescription: String? {
        switch self {
        case .missingLocalFile:
            "The local audio file is unavailable."
        }
    }
}
public struct PrepareSongForPlayback: Sendable {
    private let downloader: any RemoteMediaDownloading
    private let verifier: any MediaHashVerifying
    private let fileExists: @Sendable (URL) -> Bool

    public init(
        downloader: any RemoteMediaDownloading,
        verifier: any MediaHashVerifying,
        fileExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) {
        self.downloader = downloader
        self.verifier = verifier
        self.fileExists = fileExists
    }

    public func execute(_ location: PlaybackMediaLocation) async throws -> URL {
        switch location {
        case .local(let url):
            guard fileExists(url) else {
                throw PrepareSongError.missingLocalFile
            }
            return url
        case .remote(let media):
            let downloaded = try await downloader.download(media)
            do {
                try await verifier.verify(
                    file: downloaded,
                    expectedSHA256: media.contentHash
                )
                return downloaded
            } catch {
                try? FileManager.default.removeItem(at: downloaded)
                throw error
            }
        }
    }
}
