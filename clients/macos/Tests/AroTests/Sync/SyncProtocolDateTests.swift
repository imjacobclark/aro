#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

final class SyncProtocolDateTests: XCTestCase {
    func testDecodesRustExportManifestDatesWithNanoseconds() throws {
        let data = Data(
            """
            {
              "schema_version": 1,
              "library_name": "Mercury",
              "generated_at": "2026-07-27T08:58:08.570370131Z",
              "tracks": [
                {
                  "track_id": "04f6a564-10b5-4ad9-b1d9-8f5a9749e6ae",
                  "content_hash": "1839a19354392f02b47e7948411f0ceef96b08da73a28d3abc458aee00327ee9",
                  "byte_count": 8199334,
                  "title": "The Car",
                  "artist": "Arctic Monkeys",
                  "album": "The Car",
                  "track_number": 6,
                  "disc_number": null,
                  "original_filename": "02-01 - The Car.mp3",
                  "original_extension": "mp3",
                  "removed_at": "2026-07-27T08:58:08Z"
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder.aroSyncProtocol().decode(
            AroExportManifest.self,
            from: data
        )

        XCTAssertEqual(manifest.libraryName, "Mercury")
        XCTAssertEqual(manifest.tracks.count, 1)
        XCTAssertNotNil(manifest.tracks[0].removedAt)
    }
}
#endif
