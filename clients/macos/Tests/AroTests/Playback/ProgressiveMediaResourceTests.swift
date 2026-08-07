#if canImport(XCTest)
import CryptoKit
import Foundation
import XCTest
import AroCommon
@testable import Aro

final class ProgressiveMediaResourceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RangeURLProtocol.reset()
    }

    func testReadsOnlyDemandedBlocksAndTracksBufferedProgress() throws {
        let payload = Data("abcdefgh".utf8)
        RangeURLProtocol.payload = payload
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
        let media = RemoteMedia(
            trackID: UUID(),
            contentHash: hash,
            byteCount: Int64(payload.count),
            downloadURL: URL(string: "https://aro.test/v1/blobs/\(hash)")!
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeURLProtocol.self]
        let resource = try ProgressiveMediaResource(
            media: media,
            cacheDirectory: directory,
            session: URLSession(configuration: configuration),
            credential: nil,
            blockSize: 4,
            didVerify: { _, _, _ in }
        )

        let result = resource.read(offset: 2, length: 4)

        XCTAssertEqual(result, Data("cdef".utf8))
        XCTAssertEqual(resource.bufferedFraction, 1)
        XCTAssertEqual(
            Set(RangeURLProtocol.requestedRanges),
            Set(["bytes=0-3", "bytes=4-7"])
        )
    }

    func testAddsDeviceAuthenticationToRangeRequests() throws {
        let payload = Data("abcd".utf8)
        RangeURLProtocol.payload = payload
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
        let deviceID = UUID()
        let media = RemoteMedia(
            trackID: UUID(),
            contentHash: hash,
            byteCount: Int64(payload.count),
            downloadURL: URL(string: "https://aro.test/v1/blobs/\(hash)")!
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeURLProtocol.self]
        let resource = try ProgressiveMediaResource(
            media: media,
            cacheDirectory: directory,
            session: URLSession(configuration: configuration),
            credential: HubDeviceCredential(
                deviceID: deviceID,
                credential: "secret"
            ),
            blockSize: 4,
            didVerify: { _, _, _ in }
        )

        XCTAssertEqual(resource.read(offset: 0, length: 1), Data("a".utf8))
        XCTAssertEqual(RangeURLProtocol.authorization, "Bearer secret")
        XCTAssertEqual(
            RangeURLProtocol.deviceID,
            deviceID.uuidString
        )
    }

    func testActiveStreamingContinuouslyFillsRollingReadAhead() throws {
        let payload = Data("abcdefghijklmnopqrstuvwxyz0123456789ABCD".utf8)
        RangeURLProtocol.payload = payload
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hash = SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
        let media = RemoteMedia(
            trackID: UUID(),
            contentHash: hash,
            byteCount: Int64(payload.count),
            downloadURL: URL(string: "https://aro.test/v1/blobs/\(hash)")!
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeURLProtocol.self]
        let resource = try ProgressiveMediaResource(
            media: media,
            cacheDirectory: directory,
            session: URLSession(configuration: configuration),
            credential: nil,
            blockSize: 4,
            didVerify: { _, _, _ in }
        )
        resource.beginActiveStreaming(
            initialReadAhead: 4,
            rollingReadAhead: 12
        )

        XCTAssertEqual(resource.read(offset: 0, length: 1), Data("a".utf8))

        let deadline = Date().addingTimeInterval(1)
        while RangeURLProtocol.requestedRanges.count < 4,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(
            Set(RangeURLProtocol.requestedRanges),
            Set([
                "bytes=0-3",
                "bytes=4-7",
                "bytes=8-11",
                "bytes=12-15"
            ])
        )
    }

    func testIntegrityMismatchRemovesPartialAndNotifiesPlayback() throws {
        let payload = Data("corrupt".utf8)
        RangeURLProtocol.payload = payload
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = RemoteMedia(
            trackID: UUID(),
            contentHash: String(repeating: "0", count: 64),
            byteCount: Int64(payload.count),
            downloadURL: URL(string: "https://aro.test/v1/blobs/corrupt")!
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeURLProtocol.self]
        let resource = try ProgressiveMediaResource(
            media: media,
            cacheDirectory: directory,
            session: URLSession(configuration: configuration),
            credential: nil,
            blockSize: Int64(payload.count),
            didVerify: { _, _, _ in }
        )
        let failed = expectation(description: "integrity failure")
        resource.onIntegrityFailure { _ in failed.fulfill() }

        XCTAssertEqual(
            resource.read(offset: 0, length: payload.count),
            payload
        )
        wait(for: [failed], timeout: 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: resource.partialURL.path)
        )
    }
}

private final class RangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) private static var ranges: [String] = []
    nonisolated(unsafe) private static var auth: String?
    nonisolated(unsafe) private static var device: String?
    private static let lock = NSLock()

    static var requestedRanges: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    static var authorization: String? {
        lock.lock()
        defer { lock.unlock() }
        return auth
    }

    static var deviceID: String? {
        lock.lock()
        defer { lock.unlock() }
        return device
    }

    static func reset() {
        lock.lock()
        payload = Data()
        ranges = []
        auth = nil
        device = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let range = request.value(forHTTPHeaderField: "Range"),
              let bounds = Self.bounds(from: range) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        Self.lock.lock()
        Self.ranges.append(range)
        Self.auth = request.value(forHTTPHeaderField: "Authorization")
        Self.device = request.value(forHTTPHeaderField: "X-Aro-Device")
        let payload = Self.payload
        Self.lock.unlock()

        let data = payload.subdata(in: bounds)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range":
                    "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(payload.count)",
                "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bounds(from value: String) -> Range<Int>? {
        let specification = value
            .replacingOccurrences(of: "bytes=", with: "")
            .split(separator: "-", maxSplits: 1)
            .map(String.init)
        guard specification.count == 2,
              let start = Int(specification[0]),
              let inclusiveEnd = Int(specification[1]) else {
            return nil
        }
        return start..<(inclusiveEnd + 1)
    }
}
#endif
