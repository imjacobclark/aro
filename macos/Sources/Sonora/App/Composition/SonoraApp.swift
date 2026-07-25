import SonoraCommon

import SwiftUI

@main
@MainActor
struct SonoraApp: App {
    @State private var libraryStore: LibraryStore
    @State private var playbackController: PlaybackController
    @State private var playbackPreferences: PlaybackPreferences
    @State private var audioDeviceManager: AudioDeviceManager
    private let reviewLibraryHealth: ReviewLibraryHealth
    private let loadStatsDashboard: LoadStatsDashboard
    private let libraryFileManager: any LibraryFileManaging

    init() {
        SonoraFont.register()

        let preferences = PlaybackPreferences(
            store: UserDefaultsPlaybackPreferenceStore()
        )
        let deviceManager = AudioDeviceManager()
        let database = LibraryDatabase()
        let loudnessRepository = SQLiteLoudnessAnalysisRepository(
            database: database
        )
        let loudnessService = LoudnessAnalysisService(
            repository: loudnessRepository
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
            PlaybackSettingsView(
                preferences: playbackPreferences,
                deviceManager: audioDeviceManager,
                playback: playbackController,
                libraryFileManager: libraryFileManager
            )
            .font(SonoraFont.body)
            .tint(SonoraTheme.violet)
        }
    }
}
