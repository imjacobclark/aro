#if canImport(XCTest)
import Foundation
import XCTest
@testable import Aro

final class LegacyProductMigrationTests: XCTestCase {
    func testMovesLibraryDataAndRewritesProductPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Sonora", isDirectory: true)
        let current = root.appendingPathComponent("Aro", isDirectory: true)
        let server = legacy.appendingPathComponent(
            "Server",
            isDirectory: true
        )
        let database = legacy.appendingPathComponent("Sonora.sqlite3")
        try FileManager.default.createDirectory(
            at: server,
            withIntermediateDirectories: true
        )
        try Data("database".utf8).write(to: database)
        try Data(
            """
            data_dir = "\(legacy.path)/Library Data"
            tls_cert = "\(legacy.path)/Library Data/tls/cert.pem"
            """.utf8
        ).write(to: server.appendingPathComponent("sonora.toml"))

        try LegacyProductMigration.migrateApplicationSupport(
            from: legacy,
            to: current,
            fileManager: .default
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("Aro.sqlite3").path
            )
        )
        let config = try String(
            contentsOf: current.appendingPathComponent("Server/aro.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("/Aro/Library Data"))
        XCTAssertFalse(config.contains("/Sonora/"))
    }

    func testRewritesOnlyKnownProductLocationsAndFilenames() {
        let original =
            "/Users/test/Library/Application Support/Sonora/Sonora.sqlite3"
        XCTAssertEqual(
            LegacyProductMigration.rewrite(original),
            "/Users/test/Library/Application Support/Aro/Aro.sqlite3"
        )
        XCTAssertEqual(
            LegacyProductMigration.rewrite("/Music/Sonora/album.flac"),
            "/Music/Sonora/album.flac"
        )
    }

    func testRefusesToOverwriteDifferentPartialMigrationData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Sonora", isDirectory: true)
        let current = root.appendingPathComponent("Aro", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: current,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: legacy.appendingPathComponent("conflict")
        )
        try Data("current".utf8).write(
            to: current.appendingPathComponent("conflict")
        )

        XCTAssertThrowsError(
            try LegacyProductMigration.migrateApplicationSupport(
                from: legacy,
                to: current,
                fileManager: .default
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("conflict").path
            )
        )
    }
}
#endif
