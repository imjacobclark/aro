import Foundation
#if canImport(XCTest)
import XCTest
@testable import SonoraCommon

final class SyncTests: XCTestCase {
    func testCacheEvictionUsesLRUAndProtectsPlaybackAndPins() {
        let now = Date()
        let entries = [
            CachedBlob(contentHash: "old", byteCount: 10, lastAccessedAt: now.addingTimeInterval(-100)),
            CachedBlob(contentHash: "pin", byteCount: 10, lastAccessedAt: now.addingTimeInterval(-200), isPinned: true),
            CachedBlob(contentHash: "queue", byteCount: 10, lastAccessedAt: now.addingTimeInterval(-300), isQueued: true),
            CachedBlob(contentHash: "new", byteCount: 10, lastAccessedAt: now),
        ]
        let candidates = CacheEvictionPolicy().evictionCandidates(
            entries: entries,
            limitBytes: 25
        )
        XCTAssertEqual(candidates.map(\.contentHash), ["old", "new"])
    }

    func testRemotePlaybackDownloadsAndVerifiesBeforeReturning() async throws {
        let destination = URL(fileURLWithPath: "/cache/blob")
        let events = EventLog()
        let prepare = PrepareSongForPlayback(
            downloader: Downloader(destination: destination, events: events),
            verifier: Verifier(events: events)
        )
        let result = try await prepare.execute(
            .remote(
                RemoteMedia(
                    trackID: UUID(),
                    contentHash: String(repeating: "a", count: 64),
                    byteCount: 1,
                    downloadURL: URL(string: "https://hub/v1/blobs/a")!
                )
            )
        )
        XCTAssertEqual(result, destination)
        let values = await events.values
        XCTAssertEqual(values, ["download", "verify"])
    }

    func testConflictResolutionKeyUsesWireCanonicalUUIDCasing() {
        let timestamp = SyncFieldVersion(
            physicalMilliseconds: 1,
            logical: 0,
            deviceID: UUID()
        )
        let value = VersionedJSONValue(
            value: .string("Title"),
            timestamp: timestamp
        )
        let conflict = SyncFieldConflict(
            trackID: UUID(
                uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"
            )!,
            field: "title",
            local: value,
            hub: value
        )

        XCTAssertEqual(
            conflict.resolutionKey,
            "abcdef01-2345-6789-abcd-ef0123456789:title"
        )
    }
}

private actor EventLog {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

private struct Downloader: RemoteMediaDownloading {
    let destination: URL
    let events: EventLog
    func download(_ media: RemoteMedia) async throws -> URL {
        await events.add("download")
        return destination
    }
}

private struct Verifier: MediaHashVerifying {
    let events: EventLog
    func verify(file: URL, expectedSHA256: String) async throws {
        await events.add("verify")
    }
}
#endif
