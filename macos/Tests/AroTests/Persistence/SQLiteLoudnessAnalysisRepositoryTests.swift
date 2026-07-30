#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

final class SQLiteLoudnessAnalysisRepositoryTests: XCTestCase {
    func testAnalysesBatchLooksUpMultipleFingerprintsInOneQuery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let repository = SQLiteLoudnessAnalysisRepository(database: database)

        let matchingA = LoudnessAnalysis(
            integratedLUFS: -14,
            peakAmplitude: -1,
            analyzedAt: Date(timeIntervalSince1970: 1_000),
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        )
        let matchingB = LoudnessAnalysis(
            integratedLUFS: -16,
            peakAmplitude: -2,
            analyzedAt: Date(timeIntervalSince1970: 2_000),
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        )
        repository.save(matchingA, fingerprint: "fingerprint-a")
        repository.save(matchingB, fingerprint: "fingerprint-b")
        // Same fingerprint, different algorithm version — must not be
        // returned when querying for `LoudnessAnalysis.algorithmVersion`.
        repository.save(
            LoudnessAnalysis(
                integratedLUFS: -9,
                peakAmplitude: -0.1,
                algorithmVersion: LoudnessAnalysis.remoteAlgorithmVersion
            ),
            fingerprint: "fingerprint-a"
        )

        let results = repository.analyses(
            fingerprints: [
                "fingerprint-a", "fingerprint-b", "fingerprint-missing",
            ],
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results["fingerprint-a"]?.integratedLUFS, -14)
        XCTAssertEqual(results["fingerprint-b"]?.integratedLUFS, -16)
        XCTAssertNil(results["fingerprint-missing"])
    }

    func testAnalysesReturnsEmptyForEmptyFingerprintList() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let repository = SQLiteLoudnessAnalysisRepository(database: database)

        XCTAssertTrue(
            repository.analyses(
                fingerprints: [],
                algorithmVersion: LoudnessAnalysis.algorithmVersion
            ).isEmpty
        )
    }
}
#endif
