import Foundation
import SFBAudioEngine

actor LoudnessAnalysisService {
    private struct CacheFile: Codable {
        var analyses: [String: LoudnessAnalysis]
    }

    private var analyses: [String: LoudnessAnalysis]
    private var activeTasks: [String: Task<LoudnessAnalysis?, Never>] = [:]
    private let database: LibraryDatabase

    init(
        cacheURL: URL? = nil,
        database: LibraryDatabase = .shared
    ) {
        let resolvedURL = cacheURL ?? Self.defaultCacheURL()
        self.database = database

        if let data = try? Data(contentsOf: resolvedURL),
           let cache = try? JSONDecoder().decode(CacheFile.self, from: data) {
            analyses = cache.analyses.filter {
                $0.value.algorithmVersion == LoudnessAnalysis.algorithmVersion
            }
            for (fingerprint, analysis) in analyses {
                database.saveLoudnessAnalysis(
                    analysis,
                    fingerprint: fingerprint
                )
            }
        } else {
            analyses = [:]
        }
    }

    func cachedAnalysis(for song: Song) -> LoudnessAnalysis? {
        guard let key = song.fileFingerprint?.cacheKey else {
            return nil
        }
        return analyses[key] ?? database.loudnessAnalysis(
            fingerprint: key,
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        )
    }

    func analysis(for song: Song) async -> LoudnessAnalysis? {
        guard let key = song.fileFingerprint?.cacheKey else {
            return nil
        }

        if let cached = analyses[key] ?? database.loudnessAnalysis(
            fingerprint: key,
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        ) {
            analyses[key] = cached
            return cached
        }

        if let activeTask = activeTasks[key] {
            return await activeTask.value
        }

        let url = song.url
        let task: Task<LoudnessAnalysis?, Never> = Task.detached(
            priority: .utility
        ) {
            do {
                let replayGain = try ReplayGainAnalyzer.analyzeTrack(url)
                return LoudnessAnalysis(
                    integratedLUFS: -18 - Double(replayGain.gain),
                    peakAmplitude: Double(replayGain.peak)
                )
            } catch {
                return nil
            }
        }
        activeTasks[key] = task

        let result = await task.value
        activeTasks[key] = nil
        if let result {
            analyses[key] = result
            database.saveLoudnessAnalysis(result, fingerprint: key)
        }
        return result
    }

    func analyzeInBackground(_ songs: [Song]) async {
        for song in songs where !Task.isCancelled {
            _ = await analysis(for: song)
        }
    }

    private static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Sonora", isDirectory: true)
            .appendingPathComponent("loudness-cache.json")
    }
}
