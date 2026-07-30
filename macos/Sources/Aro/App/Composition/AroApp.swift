import AroCommon

import AppKit
import SwiftUI

@main
@MainActor
struct AroApp: App {
    @State private var runtime: LibraryRuntime
    @State private var profileRegistry: LibraryProfileRegistry
    @State private var playbackPreferences: PlaybackPreferences
    @State private var audioDeviceManager: AudioDeviceManager
    @State private var hubService = AroHubService()
    @State private var syncPreferences: SyncPreferences
    @State private var nowPlayingCoordinator: NowPlayingCoordinator

    init() {
        do {
            try LegacyProductMigration.run()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Aro Couldn’t Upgrade Your Library"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(EXIT_FAILURE)
        }
        AroFont.register()

        let preferences = PlaybackPreferences(
            store: UserDefaultsPlaybackPreferenceStore()
        )
        let deviceManager = AudioDeviceManager()
        let testRoot = ProcessInfo.processInfo.environment[
            "ARO_UI_TEST_ROOT"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let syncDefaults = testRoot.flatMap {
            UserDefaults(
                suiteName: "AroUITest.\($0.lastPathComponent)"
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
                    hub: AroHubInfo(
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
            runtime.libraryStore.selection = .settings
        }
        let nowPlayingCoordinator = NowPlayingCoordinator()
        nowPlayingCoordinator.rebind(to: runtime.playbackController)
        _nowPlayingCoordinator = State(initialValue: nowPlayingCoordinator)
        _runtime = State(initialValue: runtime)
        _profileRegistry = State(initialValue: registry)
    }

    var body: some Scene {
        WindowGroup("Aro") {
            ContentView(
                store: runtime.libraryStore,
                playback: runtime.playbackController,
                preferences: playbackPreferences,
                deviceManager: audioDeviceManager,
                profileRegistry: profileRegistry,
                hubService: hubService,
                syncPreferences: syncPreferences,
                mediaCache: runtime.mediaCacheController,
                libraryFiles: runtime.libraryFileManager,
                reviewLibraryHealth: runtime.reviewLibraryHealth,
                loadStatsDashboard: runtime.loadStatsDashboard,
                syncStore: runtime.syncOperationStore,
                removeSong: removeSong,
                setSongFavourite: setSongFavourite,
                activateProfile: activateProfile,
                forgetProfile: forgetProfile,
                completeRemoteConnection: completeRemoteConnection
            )
            .id(ObjectIdentifier(runtime))
            .frame(minWidth: 860, minHeight: 480)
            .font(AroFont.body)
            .tint(AroTheme.violet)
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
            CommandMenu("Playback") {
                Button(
                    runtime.playbackController.isPlaying ? "Pause" : "Play"
                ) {
                    runtime.playbackController.togglePlayPause()
                }
                .disabled(!runtime.playbackController.canTogglePlayback)

                Button("Next") {
                    runtime.playbackController.next()
                }
                .disabled(!runtime.playbackController.canGoNext)

                Button("Previous") {
                    runtime.playbackController.previous()
                }
                .disabled(!runtime.playbackController.canGoPrevious)
            }
        }

    }

    private func activateProfile(_ profile: LibraryProfile) {
        // A runtime owns its Core Audio graph and render callbacks. Tear it
        // down before replacing the observable object graph so SwiftUI cannot
        // render a player bar backed by a retiring controller.
        runtime.playbackController.stopAndClear()
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
        replacement.libraryStore.selection = .settings
        runtime = replacement
        nowPlayingCoordinator.rebind(to: replacement.playbackController)
        if profile.kind == .local, profile.sharingEnabled {
            if syncPreferences.dataLocation.isEmpty {
                syncPreferences.dataLocation =
                    SyncPreferences.recommendedDataLocation
            }
            hubService.setEnabled(true)
        }
    }

    /// Client-only action: disconnects this Mac from a remote library it
    /// doesn't host, deleting the local (disposable) replica database, media
    /// cache, and pairing credential. Never touches the remote server — see
    /// the app's "remote libraries are canonical, local client data is
    /// disposable" philosophy. Local (`.kind == .local`) profiles are hosted
    /// here, not just cached, so they're intentionally not eligible.
    private func forgetProfile(_ profile: LibraryProfile) {
        guard profile.kind == .remote else { return }

        if profile.id == profileRegistry.activeProfileID {
            // The active profile's database is open via `runtime`; switch
            // away first so that connection closes before its file is
            // deleted below. If there's nothing else to switch to, the
            // Settings UI is expected to have disabled this action.
            let fallback = profileRegistry.profiles.first {
                $0.id != profile.id && $0.kind == .local
            } ?? profileRegistry.profiles
                .filter { $0.id != profile.id }
                .max { $0.lastActivatedAt < $1.lastActivatedAt }
            guard let fallback else { return }
            activateProfile(fallback)
        }

        try? FileManager.default.removeItem(
            at: LibraryProfileRegistry.profileDirectory(profileID: profile.id)
        )
        if let hubID = profile.hubID {
            try? FileHubCredentialStore().remove(hubID: hubID)
        }
        profileRegistry.remove(profile.id)
    }

    private func completeRemoteConnection(
        hub: AroHubInfo,
        baseURL: URL,
        tlsFingerprint: String,
        policy: OfflineDownloadPolicy
    ) {
        let profile = profileRegistry.upsertRemote(
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

    private func setSongFavourite(
        _ song: Song,
        _ favourite: Bool
    ) async throws {
        try await runtime.setFavourite(
            trackID: song.libraryID,
            favourite: favourite
        )
    }
}
