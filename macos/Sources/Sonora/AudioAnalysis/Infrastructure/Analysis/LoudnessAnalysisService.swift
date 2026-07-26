import Foundation
import SonoraCommon
import SFBAudioEngine

actor LoudnessAnalysisService: LoudnessAnalyzing {
    private struct CacheFile: Codable {
        var analyses: [String: LoudnessAnalysis]
    }

    private var analyses: [String: LoudnessAnalysis]
    private var activeTasks: [String: Task<LoudnessAnalysis?, Never>] = [:]
    private let repository: any LoudnessAnalysisRepository

    init(
        cacheURL: URL? = nil,
        repository: any LoudnessAnalysisRepository
    ) {
        let resolvedURL = cacheURL ?? Self.defaultCacheURL()
        self.repository = repository

        if let data = try? Data(contentsOf: resolvedURL),
           let cache = try? JSONDecoder().decode(CacheFile.self, from: data) {
            analyses = cache.analyses.filter {
                $0.value.algorithmVersion == LoudnessAnalysis.algorithmVersion
            }
            for (fingerprint, analysis) in analyses {
                repository.save(
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
        return analyses[key] ?? repository.analysis(
            fingerprint: key,
            algorithmVersion: LoudnessAnalysis.algorithmVersion
        )
    }

    func analysis(for song: Song) async -> LoudnessAnalysis? {
        guard let key = song.fileFingerprint?.cacheKey else {
            return nil
        }

        if let cached = analyses[key] ?? repository.analysis(
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
        guard url.isFileURL,
              (try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isReadableKey]
              ))?.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            // SFBAudioEngine's replay-gain analyzer accepts local files only.
            // Passing a remote URL raises an Objective-C exception, which
            // cannot be caught by Swift and terminates the process.
            return nil
        }
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
            repository.save(result, fingerprint: key)
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
