import SwiftUI
import SonoraCommon

@MainActor
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            store: LibraryStore(
                scanFolder: ScanWatchedFolder(
                    scanner: PreviewAudioScanner(),
                    catalog: PreviewLibraryCatalog()
                ),
                analyzeSongLoudness: AnalyzeSongLoudness(
                    analyzer: PreviewLoudnessAnalyzer()
                ),
                manageFolders: ManageWatchedFolders(
                    catalog: PreviewLibraryCatalog()
                ),
                monitorFactory: PreviewFolderMonitorFactory(),
                folderAccess: PreviewFolderAccess(),
                legacyFolders: InMemoryLegacyWatchedFolderStore()
            ),
            playback: PlaybackController(),
            preferences: PlaybackPreferences(),
            deviceManager: AudioDeviceManager(),
            reviewLibraryHealth: ReviewLibraryHealth(
                tracks: PreviewLibraryHealthTracks()
            ),
            loadStatsDashboard: LoadStatsDashboard(
                stats: PreviewStatsQuery()
            )
        )
        .frame(width: 900, height: 600)
    }
}

private struct PreviewLibraryHealthTracks: LibraryHealthTrackQuerying {
    func libraryHealthTracks() -> [LibraryHealthTrack] {
        []
    }
}

private struct PreviewStatsQuery: StatsQuerying {
    func listeningStats(now: Date) -> ListeningStats {
        ListeningStats()
    }

    func libraryStats() -> LibraryStats {
        LibraryStats()
    }
}

private struct PreviewAudioScanner: AudioScanning {
    func scan(folder: URL) async -> ScanResult {
        ScanResult(songs: [], skippedFileCount: 0)
    }
}

private struct PreviewLoudnessAnalyzer: LoudnessAnalyzing {
    func cachedAnalysis(for song: Song) async -> LoudnessAnalysis? {
        nil
    }

    func analysis(for song: Song) async -> LoudnessAnalysis? {
        nil
    }

    func analyzeInBackground(_ songs: [Song]) async {}
}

private struct PreviewLibraryCatalog: LibraryCatalogRepository {
    func watchedFolders() -> [StoredWatchedFolder] {
        []
    }

    func save(folder: WatchedFolder) {}
    func removeFolder(id: UUID) {}
    func markFolderUnavailable(id: UUID) {}

    func songs(folderID: UUID) -> [Song] {
        []
    }

    func reconcile(songs: [Song], folderID: UUID) -> [Song] {
        songs
    }
}

private struct PreviewFolderMonitorFactory: FolderMonitorCreating {
    func makeMonitor(
        for url: URL,
        handler: @escaping @Sendable () -> Void
    ) -> (any FolderMonitoring)? {
        nil
    }
}

private struct PreviewFolderAccess: FolderAccessing {
    func normalizedURL(_ url: URL) -> URL {
        url
    }

    func bookmarkData(for url: URL) -> Data? {
        nil
    }

    func beginAccessing(_ url: URL) -> Bool {
        false
    }

    func endAccessing(_ url: URL) {}

    func isAccessibleDirectory(_ url: URL) -> Bool {
        true
    }

    func resolve(
        path: String,
        bookmarkData: Data?
    ) -> ResolvedFolderAccess {
        ResolvedFolderAccess(
            url: URL(fileURLWithPath: path),
            bookmarkData: bookmarkData,
            didStartSecurityScope: false
        )
    }
}
