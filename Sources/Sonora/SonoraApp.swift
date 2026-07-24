import SwiftUI

@main
@MainActor
struct SonoraApp: App {
    @State private var libraryStore: LibraryStore
    @State private var playbackController: PlaybackController
    @State private var playbackPreferences: PlaybackPreferences
    @State private var audioDeviceManager: AudioDeviceManager

    init() {
        SonoraFont.register()

        let preferences = PlaybackPreferences()
        let deviceManager = AudioDeviceManager()
        let loudnessService = LoudnessAnalysisService()

        _playbackPreferences = State(initialValue: preferences)
        _audioDeviceManager = State(initialValue: deviceManager)
        _libraryStore = State(
            initialValue: LibraryStore(loudnessService: loudnessService)
        )
        _playbackController = State(
            initialValue: PlaybackController(
                preferences: preferences,
                deviceManager: deviceManager,
                loudnessService: loudnessService
            )
        )
    }

    var body: some Scene {
        WindowGroup("Sonora") {
            ContentView(
                store: libraryStore,
                playback: playbackController
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
                playback: playbackController
            )
            .font(SonoraFont.body)
            .tint(SonoraTheme.violet)
        }
    }
}
