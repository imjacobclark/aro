#if canImport(XCTest)
import Foundation
import XCTest
@testable import Aro

final class DiscoveryAndLocalServerTests: XCTestCase {
    func testBonjourCandidateUsesAdvertisedHubIdentityAndHost() throws {
        let hubID = UUID()
        let candidate = try XCTUnwrap(
            AroHubBrowser.candidate(
                name: "Cached Name",
                domain: "local.",
                txt: [
                    "hub_id": hubID.uuidString.lowercased(),
                    "name": "Living Room",
                    "host": "aro-12345678.local.",
                ]
            )
        )

        XCTAssertEqual(candidate.hubID, hubID)
        XCTAssertEqual(candidate.name, "Living Room")
        XCTAssertEqual(
            candidate.address,
            "https://aro-12345678.local.:4848"
        )
    }

    func testAdvertisementWithoutUniqueHostIsRejected() {
        XCTAssertNil(
            AroHubBrowser.candidate(
                name: "Old Hub",
                domain: "local.",
                txt: ["hub_id": UUID().uuidString]
            )
        )
    }

    func testLocalServerConfigurationParsingAndPathWithSpaces() {
        let config = LocalAroServerMonitor.parseConfiguration(
            """
            hub_id = "e592e8f0-38b4-4da7-9625-4d2dd8f8c7db"
            display_name = "Jacob's Hub"
            data_dir = "/Users/jacob/Hub Data"
            bind = "0.0.0.0:4848"
            """
        )

        XCTAssertEqual(config["display_name"], "Jacob's Hub")
        XCTAssertEqual(config["data_dir"], "/Users/jacob/Hub Data")
        XCTAssertEqual(
            LocalAroServerMonitor.configurationPath(
                command: "aro-server --config /Users/jacob/Hub Data/config.toml serve",
                kind: .standalone,
                homeDirectory: URL(fileURLWithPath: "/Users/jacob")
            ),
            "/Users/jacob/Hub Data/config.toml"
        )
    }
}
#endif
