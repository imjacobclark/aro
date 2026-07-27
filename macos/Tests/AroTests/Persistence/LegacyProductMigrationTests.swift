#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import Aro

final class LegacyProductMigrationTests: XCTestCase {
    func testMovesLibraryDataAndRewritesProductPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
        let legacy = applicationSupport.appendingPathComponent(
            "Sonora",
            isDirectory: true
        )
        let current = applicationSupport.appendingPathComponent(
            "Aro",
            isDirectory: true
        )
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
        XCTAssertEqual(
            LegacyProductMigration.rewrite(
                #"https:\/\/sonora-d7e2db96.local.:4848"#
            ),
            #"https:\/\/aro-d7e2db96.local.:4848"#
        )
        XCTAssertEqual(
            LegacyProductMigration.rewrite(
                #"\/Users\/test\/Library\/Application Support\/Sonora\/Libraries"#
            ),
            #"\/Users\/test\/Library\/Application Support\/Aro\/Libraries"#
        )
    }

    func testRepairsCurrentProfileAndMembershipURLAfterV1Migration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("Library.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE hub_memberships (base_url TEXT NOT NULL);
                INSERT INTO hub_memberships VALUES (
                    'https://sonora-d7e2db96.local.:4848'
                );
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        let suiteName = "AroMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(
                #"""
                {"databasePath":"\/Users\/test\/Library\/Application Support\/Sonora\/Libraries\/Library.sqlite3","baseURL":"https:\/\/sonora-d7e2db96.local.:4848"}
                """#.utf8
            ),
            forKey: "library.profileRegistry.v1"
        )

        try LegacyProductMigration.repairCurrentState(
            applicationSupportRoot: root,
            defaults: defaults,
            fileManager: .default
        )

        let repairedData = try XCTUnwrap(
            defaults.data(forKey: "library.profileRegistry.v1")
        )
        let repairedProfile = try XCTUnwrap(
            String(data: repairedData, encoding: .utf8)
        )
        XCTAssertTrue(repairedProfile.contains(#"Support\/Aro\/Libraries"#))
        XCTAssertTrue(repairedProfile.contains(#"https:\/\/aro-d7e2db96"#))
        XCTAssertFalse(repairedProfile.contains("Sonora"))

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "SELECT base_url FROM hub_memberships",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(
            String(cString: sqlite3_column_text(query, 0)),
            "https://aro-d7e2db96.local.:4848"
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
