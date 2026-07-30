public protocol LoudnessAnalysisRepository: Sendable {
    func analysis(fingerprint: String, algorithmVersion: Int) -> LoudnessAnalysis?
    /// Looks up several fingerprints in a single query, keyed by fingerprint —
    /// used to enrich a batch of songs without issuing one query per song.
    func analyses(fingerprints: [String], algorithmVersion: Int) -> [String: LoudnessAnalysis]
    func save(_ analysis: LoudnessAnalysis, fingerprint: String)
}

public protocol LoudnessAnalyzing: Sendable {
    func cachedAnalysis(for song: Song) async -> LoudnessAnalysis?
    func analysis(for song: Song) async -> LoudnessAnalysis?
    func analyzeInBackground(_ songs: [Song]) async
}

public struct AnalyzeSongLoudness: Sendable {
    private let analyzer: any LoudnessAnalyzing

    public init(analyzer: any LoudnessAnalyzing) {
        self.analyzer = analyzer
    }

    public func execute(song: Song) async -> LoudnessAnalysis? {
        await analyzer.analysis(for: song)
    }
}

public struct NoOpLoudnessAnalyzer: LoudnessAnalyzing, Sendable {
    public init() {}

    public func cachedAnalysis(for song: Song) async -> LoudnessAnalysis? { nil }
    public func analysis(for song: Song) async -> LoudnessAnalysis? { nil }
    public func analyzeInBackground(_ songs: [Song]) async {}
}
