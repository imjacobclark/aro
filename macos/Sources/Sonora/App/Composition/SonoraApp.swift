import SonoraCommon

import SwiftUI

@main
@MainActor
struct SonoraApp: App {
    @State private var libraryStore: LibraryStore
    @State private var playbackController: PlaybackController
    @State private var playbackPreferences: PlaybackPreferences
    @State private var audioDeviceManager: AudioDeviceManager
    @State private var hubService = SonoraHubService()
    @State private var syncPreferences = SyncPreferences()
    @State private var mediaCacheController: MediaCacheController
    private let reviewLibraryHealth: ReviewLibraryHealth
    private let loadStatsDashboard: LoadStatsDashboard
    private let libraryFileManager: any LibraryFileManaging
    private let syncOperationStore: SQLiteSyncOperationStore

    init() {
        SonoraFont.register()

        let preferences = PlaybackPreferences(
            store: UserDefaultsPlaybackPreferenceStore()
        )
        let deviceManager = AudioDeviceManager()
        let database = LibraryDatabase()
        syncOperationStore = SQLiteSyncOperationStore(database: database)
        _mediaCacheController = State(
            initialValue: MediaCacheController(database: database)
        )
        let loudnessRepository = SQLiteLoudnessAnalysisRepository(
            database: database
        )
        let loudnessService = LoudnessAnalysisService(
            repository: loudnessRepository
        )
        let mediaCacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Sonora/Media", isDirectory: true)
        let prepareSong = PrepareSongForPlayback(
            downloader: URLSessionMediaDownloader(
                cacheDirectory: mediaCacheDirectory
            ),
            verifier: CachingSHA256MediaVerifier(
                cache: SQLiteMediaCache(database: database)
            )
        )
        libraryFileManager = SQLiteLibraryFileManager(
            database: database
        )
        let libraryCatalog = SQLiteLibraryCatalogRepository(
            database: database,
            loudness: loudnessRepository
        )
        let libraryHealthTracks = SQLiteLibraryHealthTrackQuery(
            database: database
        )
        reviewLibraryHealth = ReviewLibraryHealth(
            tracks: libraryHealthTracks
        )
        loadStatsDashboard = LoadStatsDashboard(
            stats: SQLiteStatsQuery(database: database)
        )

        _playbackPreferences = State(initialValue: preferences)
        _audioDeviceManager = State(initialValue: deviceManager)
        _libraryStore = State(
            initialValue: LibraryStore(
                scanFolder: ScanWatchedFolder(
                    scanner: AudioScanner(
                        contentHashCache: SQLiteContentHashCache(
                            database: database
                        )
                    ),
                    catalog: libraryCatalog
                ),
                analyzeSongLoudness: AnalyzeSongLoudness(
                    analyzer: loudnessService
                ),
                manageFolders: ManageWatchedFolders(
                    catalog: libraryCatalog
                ),
                monitorFactory: FSEventsFolderMonitorFactory(),
                folderAccess: SecurityScopedFolderAccess(),
                legacyFolders: UserDefaultsLegacyWatchedFolderStore()
            )
        )
        _playbackController = State(
            initialValue: PlaybackController(
                preferences: preferences,
                loudnessService: loudnessService,
                listeningHistory: SQLiteListeningHistoryRecorder(
                    database: database
                ),
                effectiveModeResolver: {
                    PlaybackRoutePolicy().effectiveMode(
                        preferredMode: preferences.mode,
                        device: deviceManager.selectedDevice(for: preferences.outputDeviceUID)
                    )
                },
                prepareSong: prepareSong,
                mediaLocationResolver: { song in
                    guard !song.url.isFileURL,
                          let hash = song.fileFingerprint?.contentHash,
                          let byteCount = song.fileSizeBytes else {
                        return nil
                    }
                    return .remote(
                        RemoteMedia(
                            trackID: song.libraryID,
                            contentHash: hash,
                            byteCount: byteCount,
                            downloadURL: song.url
                        )
                    )
                },
                engineFactory: {
                    HighResolutionPlaybackEngine(
                        preferences: preferences,
                        deviceManager: deviceManager
                    )
                }
            )
        )
    }

    var body: some Scene {
        WindowGroup("Sonora") {
            ContentView(
                store: libraryStore,
                playback: playbackController,
                preferences: playbackPreferences,
                deviceManager: audioDeviceManager,
                reviewLibraryHealth: reviewLibraryHealth,
                loadStatsDashboard: loadStatsDashboard
            )
            .frame(minWidth: 860, minHeight: 480)
            .font(SonoraFont.body)
            .tint(SonoraTheme.violet)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            TabView {
                Tab("Playback", systemImage: "speaker.wave.2") {
                    PlaybackSettingsView(
                        preferences: playbackPreferences,
                        deviceManager: audioDeviceManager,
                        playback: playbackController,
                        libraryFileManager: libraryFileManager
                    )
                }
                Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                    SyncSettingsView(
                        service: hubService,
                        preferences: syncPreferences,
                        mediaCache: mediaCacheController,
                        syncStore: syncOperationStore,
                        libraryFiles: libraryFileManager
                    )
                }
            }
            .font(SonoraFont.body)
            .tint(SonoraTheme.violet)
        }
    }
}
