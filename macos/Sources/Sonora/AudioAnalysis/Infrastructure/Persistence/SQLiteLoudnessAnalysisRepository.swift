import Foundation
import SonoraCommon
import SQLite3

struct SQLiteLoudnessAnalysisRepository: LoudnessAnalysisRepository {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func analysis(
        fingerprint: String,
        algorithmVersion: Int
    ) -> LoudnessAnalysis? {
        database.withReadConnection { connection in
            guard let statement = prepare(
                """
                SELECT integrated_lufs, peak_amplitude, analyzed_at
                FROM loudness_analysis
                WHERE fingerprint = ? AND algorithm_version = ?
                """,
                connection: connection
            ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            bind(fingerprint, to: statement, at: 1)
            sqlite3_bind_int(statement, 2, Int32(algorithmVersion))
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return LoudnessAnalysis(
                integratedLUFS: sqlite3_column_double(statement, 0),
                peakAmplitude: sqlite3_column_double(statement, 1),
                analyzedAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(
                        statement,
                        2
                    )
                ),
                algorithmVersion: algorithmVersion
            )
        } ?? nil
    }

    func save(
        _ analysis: LoudnessAnalysis,
        fingerprint: String
    ) {
        database.withConnection { connection in
            guard let statement = prepare(
                """
                INSERT INTO loudness_analysis
                    (fingerprint, algorithm_version, integrated_lufs,
                     peak_amplitude, analyzed_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(fingerprint, algorithm_version) DO UPDATE SET
                    integrated_lufs = excluded.integrated_lufs,
                    peak_amplitude = excluded.peak_amplitude,
                    analyzed_at = excluded.analyzed_at
                """,
                connection: connection
            ) else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(fingerprint, to: statement, at: 1)
            sqlite3_bind_int(
                statement,
                2,
                Int32(analysis.algorithmVersion)
            )
            sqlite3_bind_double(statement, 3, analysis.integratedLUFS)
            sqlite3_bind_double(statement, 4, analysis.peakAmplitude)
            sqlite3_bind_double(
                statement,
                5,
                analysis.analyzedAt.timeIntervalSince1970
            )
            sqlite3_step(statement)
        }
    }

    private func prepare(
        _ sql: String,
        connection: OpaquePointer
    ) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
