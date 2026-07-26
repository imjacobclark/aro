import SonoraCommon

import SwiftUI

@main
@MainActor
struct SonoraApp: App {
    @State private var runtime: LibraryRuntime
    @State private var profileRegistry: LibraryProfileRegistry
    @State private var playbackPreferences: PlaybackPreferences
    @State private var audioDeviceManager: AudioDeviceManager
    @State private var hubService = SonoraHubService()
    @State private var syncPreferences: SyncPreferences

    init() {
        SonoraFont.register()

        let preferences = PlaybackPreferences(
            store: UserDefaultsPlaybackPreferenceStore()
        )
        let deviceManager = AudioDeviceManager()
        let testRoot = ProcessInfo.processInfo.environment[
            "SONORA_UI_TEST_ROOT"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let syncDefaults = testRoot.flatMap {
            UserDefaults(
                suiteName: "SonoraUITest.\($0.lastPathComponent)"
            )
        } ?? .standard
        _playbackPreferences = State(initialValue: preferences)
        _audioDeviceManager = State(initialValue: deviceManager)
        _syncPreferences = State(
            initialValue: SyncPreferences(defaults: syncDefaults)
        )
        let registry = LibraryProfileRegistry(defaults: syncDefaults)
        let selectedProfile = registry.activeProfile
        let databaseURL = selectedProfile.map {
            URL(fileURLWithPath: $0.databasePath)
        } ?? testRoot?.appendingPathComponent("Library.sqlite3")
            ?? LibraryDatabase.defaultURL()
        let runtime = LibraryRuntime(
            databaseURL: databaseURL,
            playbackPreferences: preferences,
            audioDeviceManager: deviceManager,
            mediaDirectory: selectedProfile.map {
                URL(fileURLWithPath: $0.mediaPath)
            },
            profile: selectedProfile
        )
        registry.migrateLegacyState(
            databaseURL: databaseURL,
            hasLocalLibrary: !runtime.libraryStore.folders.isEmpty,
            hostingDataLocation: syncDefaults.string(
                forKey: "sync.host.dataLocation"
            ) ?? "",
            memberships: runtime.syncOperationStore.membershipSummaries,
            deviceName: Host.current().localizedName ?? "This Mac",
            prepareRemoteProfile: { profile, membership in
                let database = LibraryDatabase(
                    url: URL(fileURLWithPath: profile.databasePath)
                )
                SQLiteSyncOperationStore(database: database).upsertMembership(
                    hub: SonoraHubInfo(
                        hubID: membership.hubID,
                        displayName: membership.displayName,
                        protocolMin: 2,
                        protocolMax: 4,
                        pairingAvailable: false
                    ),
                    baseURL: membership.baseURL,
                    tlsFingerprint: membership.tlsFingerprint,
                    replicaMode: membership.replicaMode
                )
            }
        )
        if !registry.isConfigured {
            runtime.libraryStore.selection = .devices
        }
        _runtime = State(initialValue: runtime)
        _profileRegistry = State(initialValue: registry)
    }

    var body: some Scene {
        WindowGroup("Sonora") {
            ContentView(
                store: runtime.libraryStore,
                playback: runtime.playbackController,
                preferences: playbackPreferences,
                deviceManager: audioDeviceManager,
                profileRegistry: profileRegistry,
                hubService: hubService,
                syncPreferences: syncPreferences,
                mediaCache: runtime.mediaCacheController,
                reviewLibraryHealth: runtime.reviewLibraryHealth,
                loadStatsDashboard: runtime.loadStatsDashboard,
                syncStore: runtime.syncOperationStore,
                libraryFiles: runtime.libraryFileManager,
                removeSong: removeSong,
                activateProfile: activateProfile,
                completeRemoteConnection: completeRemoteConnection
            )
            .frame(minWidth: 860, minHeight: 480)
            .font(SonoraFont.body)
            .tint(SonoraTheme.violet)
            .task {
                await hubService.ensureCompatibleHelper(
                    dataLocation: syncPreferences.dataLocation
                )
            }
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
                        playback: runtime.playbackController,
                        libraryFileManager: runtime.libraryFileManager
                    )
                }
                Tab("Devices", systemImage: "macbook.and.iphone") {
                    SyncSettingsView(
                        service: hubService,
                        preferences: syncPreferences,
                        mediaCache: runtime.mediaCacheController,
                        syncStore: runtime.syncOperationStore,
                        libraryFiles: runtime.libraryFileManager,
                        activeProfile: profileRegistry.activeProfile
                    )
                }
            }
            .font(SonoraFont.body)
            .tint(SonoraTheme.violet)
        }
    }

    private func activateProfile(_ profile: LibraryProfile) {
        profileRegistry.activate(profile.id)
        if profile.kind == .remote, hubService.isEnabled {
            hubService.setEnabled(false)
        }
        let replacement = LibraryRuntime(
            databaseURL: URL(fileURLWithPath: profile.databasePath),
            playbackPreferences: playbackPreferences,
            audioDeviceManager: audioDeviceManager,
            mediaDirectory: URL(fileURLWithPath: profile.mediaPath),
            profile: profile
        )
        let initialPaths = profile.managedMusicPath.map { [$0] }
            ?? profile.referencedMusicPaths
        for path in initialPaths {
            replacement.libraryStore.addFolder(URL(fileURLWithPath: path))
        }
        replacement.libraryStore.selection = .devices
        runtime = replacement
        if profile.kind == .local, profile.sharingEnabled {
            if syncPreferences.dataLocation.isEmpty {
                syncPreferences.dataLocation =
                    SyncPreferences.recommendedDataLocation
            }
            hubService.setEnabled(true)
        }
    }

    private func completeRemoteConnection(
        hub: SonoraHubInfo,
        baseURL: URL,
        tlsFingerprint: String,
        policy: OfflineDownloadPolicy
    ) {
        let profile = profileRegistry.createRemote(
            name: hub.displayName,
            hubID: hub.hubID,
            baseURL: baseURL,
            policy: policy
        )
        let database = LibraryDatabase(
            url: URL(fileURLWithPath: profile.databasePath)
        )
        SQLiteSyncOperationStore(database: database).upsertMembership(
            hub: hub,
            baseURL: baseURL,
            tlsFingerprint: tlsFingerprint,
            replicaMode: policy == .fullLibrary ? .fullMirror : .onDemand
        )
        activateProfile(profile)
    }

    private func removeSong(_ song: Song) async throws {
        if profileRegistry.activeProfile?.kind == .local,
           let hash = song.fileFingerprint?.contentHash {
            if syncPreferences.dataLocation.isEmpty {
                syncPreferences.dataLocation =
                    SyncPreferences.recommendedDataLocation
            }
            let wasEnabled = hubService.isEnabled
            if !wasEnabled {
                hubService.setEnabled(true)
                await hubService.ensureCompatibleHelper(
                    dataLocation: syncPreferences.dataLocation
                )
            }
            defer {
                if !wasEnabled {
                    hubService.setEnabled(false)
                }
            }
            let control = HubControlClient(
                socketURL: URL(
                    fileURLWithPath: syncPreferences.dataLocation
                ).appendingPathComponent("control.sock")
            )
            for attempt in 0 ..< 25 {
                do {
                    try await control.removeTrack(contentHash: hash)
                    break
                } catch where attempt < 24 {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        try runtime.removeFromLibrary(trackID: song.libraryID)
    }
}
