import CryptoKit
import Foundation
import SonoraCommon

enum MediaVerificationError: LocalizedError {
    case hashMismatch

    var errorDescription: String? {
        "The downloaded audio failed SHA-256 verification."
    }
}

enum MediaDownloadError: LocalizedError {
    case savedCertificateMismatch

    var errorDescription: String? {
        "The library’s certificate no longer matches the certificate saved during pairing. Reconnect to the library before downloading music."
    }
}

struct SHA256MediaVerifier: MediaHashVerifying {
    func verify(file: URL, expectedSHA256: String) async throws {
        let digest = try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 128 * 1_024),
                  !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        }.value
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw MediaVerificationError.hashMismatch
        }
    }
}

actor URLSessionMediaDownloader: RemoteMediaDownloading {
    private let cacheDirectory: URL
    private let session: URLSession
    private let credential: HubDeviceCredential?

    init(
        cacheDirectory: URL,
        session: URLSession? = nil,
        credential: HubDeviceCredential? = nil,
        pinnedTLSFingerprint: String? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        if let session {
            self.session = session
        } else if let pinnedTLSFingerprint,
                  !pinnedTLSFingerprint.isEmpty {
            self.session = URLSession(
                configuration: .default,
                delegate: PinnedTLSDelegate(
                    fingerprint: pinnedTLSFingerprint
                ),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession(configuration: .default)
        }
        self.credential = credential
    }

    func download(_ media: RemoteMedia) async throws -> URL {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let destination = cacheDirectory.appendingPathComponent(
            media.contentHash
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let partial = destination.appendingPathExtension("partial")
        var request = URLRequest(url: media.downloadURL)
        if let credential {
            request.setValue(
                "Bearer \(credential.credential)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                credential.deviceID.uuidString,
                forHTTPHeaderField: "X-Sonora-Device"
            )
        }
        let offset = (try? partial.resourceValues(forKeys: [.fileSizeKey]))
            .flatMap(\.fileSize) ?? 0
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch let error as URLError
            where error.code == .serverCertificateUntrusted
                || error.code == .secureConnectionFailed {
            throw MediaDownloadError.savedCertificateMismatch
        }
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        if offset > 0, http.statusCode == 206 {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try output.seekToEnd()
            let input = try FileHandle(forReadingFrom: temporaryURL)
            defer { try? input.close() }
            try output.write(contentsOf: input.readDataToEndOfFile())
        } else {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(
                at: temporaryURL,
                to: partial
            )
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }
}
