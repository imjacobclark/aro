import SwiftUI
import AroCommon

@MainActor
struct ContentView_Previews: PreviewProvider {
    private static let preferences = PlaybackPreferences()
    private static let deviceManager = AudioDeviceManager()
    private static let runtime = LibraryRuntime(
        databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AroPreview.sqlite3"),
        playbackPreferences: preferences,
        audioDeviceManager: deviceManager
    )

    static var previews: some View {
        ContentView(
            store: runtime.libraryStore,
            playback: runtime.playbackController,
            preferences: preferences,
            deviceManager: deviceManager,
            profileRegistry: LibraryProfileRegistry(
                defaults: UserDefaults(suiteName: "AroPreview")!
            ),
            hubService: AroHubService(),
            syncPreferences: SyncPreferences(
                defaults: UserDefaults(suiteName: "AroPreview")!
            ),
            mediaCache: runtime.mediaCacheController,
            reviewLibraryHealth: runtime.reviewLibraryHealth,
            loadStatsDashboard: runtime.loadStatsDashboard,
            syncStore: runtime.syncOperationStore,
            libraryFiles: runtime.libraryFileManager,
            removeSong: { _ in },
            activateProfile: { _ in },
            completeRemoteConnection: { _, _, _, _ in }
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
