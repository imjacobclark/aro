#if canImport(Testing)
import Foundation
import AroCommon
import Testing
@testable import Aro

@Suite("Loudness analysis")
struct LoudnessAnalysisServiceTests {
    @Test("Remote media is never passed to the local audio decoder")
    func skipsRemoteMedia() async {
        let service = LoudnessAnalysisService(
            cacheURL: URL(fileURLWithPath: "/private/tmp/aro-missing-loudness-cache.json"),
            repository: EmptyLoudnessRepository()
        )
        let song = Song(
            url: URL(string: "https://mercury:4848/v1/blobs/abc123")!,
            title: "Remote song",
            artist: "Artist",
            duration: 180,
            fileSizeBytes: 1_024,
            fileFingerprint: AudioFileFingerprint(
                standardizedPath: "remote/abc123",
                fileSizeBytes: 1_024,
                modificationDate: .distantPast,
                contentHash: "abc123"
            )
        )

        #expect(await service.analysis(for: song) == nil)
    }

    @Test("A missing local file is skipped safely")
    func skipsMissingLocalMedia() async {
        let service = LoudnessAnalysisService(
            cacheURL: URL(fileURLWithPath: "/private/tmp/aro-missing-loudness-cache.json"),
            repository: EmptyLoudnessRepository()
        )
        let song = Song(
            url: URL(fileURLWithPath: "/private/tmp/aro-file-that-does-not-exist.flac"),
            title: "Missing song",
            artist: "Artist",
            duration: 180,
            fileFingerprint: AudioFileFingerprint(
                standardizedPath: "/private/tmp/aro-file-that-does-not-exist.flac",
                fileSizeBytes: 1_024,
                modificationDate: .distantPast,
                contentHash: "missing"
            )
        )

        #expect(await service.analysis(for: song) == nil)
    }
}

private struct EmptyLoudnessRepository: LoudnessAnalysisRepository {
    func analysis(
        fingerprint: String,
        algorithmVersion: Int
    ) -> LoudnessAnalysis? {
        nil
    }

    func analyses(
        fingerprints: [String],
        algorithmVersion: Int
    ) -> [String: LoudnessAnalysis] {
        [:]
    }

    func save(_ analysis: LoudnessAnalysis, fingerprint: String) {}
}
#endif
