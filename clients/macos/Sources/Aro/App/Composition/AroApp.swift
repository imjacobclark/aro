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
        let syncPreferences = SyncPreferences(defaults: syncDefaults)
        _syncPreferences = State(initialValue: syncPreferences)
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
            profile: selectedProfile,
            localAdminToken: syncPreferences.localAdminToken
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
        // Aro follows the system output device. macOS is the single authority on where
        // sound goes, so a change there re-routes playback instead of leaving Aro playing
        // into the device that was default when the track started.
        let playbackController = runtime.playbackController
        deviceManager.defaultDeviceDidChange = { device in
            MainActor.assumeIsolated {
                playbackController.systemOutputDeviceChanged(to: device)
            }
        }
        // Exclusive access and a changed device sample rate are global side effects that
        // outlive the process. CoreAudio reclaims hog mode when Aro exits, but the device
        // is left at whatever rate bit-perfect set — so quitting mid-track used to leave a
        // DAC running at 96 kHz for everything else on the machine. Stopping playback runs
        // the existing release path.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                playbackController.stopAndClear()
            }
        }
        let nowPlayingCoordinator = NowPlayingCoordinator()
        nowPlayingCoordinator.rebind(to: runtime.playbackController)
        _nowPlayingCoordinator = State(initialValue: nowPlayingCoordinator)
        _runtime = State(initialValue: runtime)
        _profileRegistry = State(initialValue: registry)

        // The local hub is always-on infrastructure, not an opt-in "sharing"
        // feature: every `.local` profile (including a brand-new one, where
        // `selectedProfile` is still nil) needs its own hub running to scan,
        // hash, and identify anything, whether or not the user ever turns on
        // LAN sharing/pairing on top of it.
        if selectedProfile == nil || registry.profiles.contains(where: {
            $0.kind == .local
        }) {
            if syncPreferences.dataLocation.isEmpty {
                self.syncPreferences.dataLocation =
                    SyncPreferences.recommendedDataLocation
            }
            hubService.setEnabled(true)
        }
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
                await enforceLocalServerExposure()
                // The control socket is bootstrap-only: learn the local hub's
                // endpoint and certificate identity, persist them on the
                // profile, then rebuild the runtime so all normal catalogue
                // and media traffic uses pinned loopback HTTPS.
                if await bootstrapLocalServerProfile() {
                    return
                }
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
        let replacement = LibraryRuntime(
            databaseURL: URL(fileURLWithPath: profile.databasePath),
            playbackPreferences: playbackPreferences,
            audioDeviceManager: audioDeviceManager,
            mediaDirectory: URL(fileURLWithPath: profile.mediaPath),
            profile: profile,
            localAdminToken: syncPreferences.localAdminToken
        )
        replacement.libraryStore.selection = .settings
        runtime = replacement
        nowPlayingCoordinator.rebind(to: replacement.playbackController)
        // The local hub is always-on: every `.local` profile gets one, whether
        // or not LAN sharing/pairing is ever turned on on top of it (see
        // `init()`'s matching comment). Folders are imported through it rather
        // than scanned in-process -- this Mac's library is a replica of its
        // its catalogue over the same pinned HTTPS API used for a remote hub.
        if profile.kind == .local {
            if syncPreferences.dataLocation.isEmpty {
                syncPreferences.dataLocation =
                    SyncPreferences.recommendedDataLocation
            }
            hubService.setEnabled(true)
            // Always the user's actual chosen folder(s), never
            // `managedMusicPath` itself: that's an empty destination
            // directory at this point (see `LibrarySetupView.createLibrary()`)
            // -- the *source* to import is always `referencedMusicPaths`,
            // with `mode` alone telling the hub whether to copy it into its
            // own managed blob store or just index it in place.
            let initialPaths = profile.referencedMusicPaths
            Task {
                await importInitialFoldersAndSync(
                    paths: initialPaths,
                    into: replacement
                )
            }
        }
    }

    /// Returns true when the runtime was replaced. The enclosing `.task` is
    /// tied to that runtime and should finish so its replacement can start a
    /// fresh synchronization loop with the newly persisted server session.
    private func bootstrapLocalServerProfile() async -> Bool {
        guard var profile = profileRegistry.activeProfile,
              profile.kind == .local,
              !syncPreferences.dataLocation.isEmpty,
              let adminToken = syncPreferences.localAdminToken,
              !adminToken.isEmpty else {
            return false
        }
        let control = HubControlClient(
            socketURL: URL(fileURLWithPath: syncPreferences.dataLocation)
                .appendingPathComponent("control.sock")
        )
        do {
            let status = try await control.status()
            guard let baseURL = URL(
                string: "https://127.0.0.1:\(status.httpsPort)"
            ) else { return false }
            let client = AroSyncClient(
                localAdminBaseURL: baseURL,
                adminToken: adminToken,
                pinnedTLSFingerprint: status.tlsFingerprint
            )
            let hub = try await client.compatibleHubInfo()
            guard hub.hubID == status.hubID else { return false }

            runtime.syncOperationStore.upsertMembership(
                hub: hub,
                baseURL: baseURL,
                tlsFingerprint: status.tlsFingerprint,
                replicaMode: .onDemand
            )
            let changed = profile.hubID != hub.hubID
                || profile.baseURL != baseURL
            profile.hubID = hub.hubID
            profile.baseURL = baseURL
            profile.name = hub.displayName
            profileRegistry.update(profile)
            guard changed else { return false }
            activateProfile(profile)
            return true
        } catch {
            hubService.errorMessage = "The local library server could not be "
                + "authenticated: \(error.localizedDescription)"
            return false
        }
    }

    /// LAN visibility is a property of the hosted profile, not of whether the
    /// server process is running. The process stays available on loopback for
    /// all local-library work even when sharing is switched off.
    private func enforceLocalServerExposure() async {
        guard !syncPreferences.dataLocation.isEmpty else { return }
        let profile = profileRegistry.profiles.first { $0.kind == .local }
        let sharing = profile?.sharingEnabled ?? false
        let port = profile?.baseURL?.port ?? 4848
        let desiredBind = sharing ? "[::]:\(port)" : "127.0.0.1:\(port)"
        let desiredMDNS = sharing ? "true" : "false"
        let control = HubControlClient(
            socketURL: URL(fileURLWithPath: syncPreferences.dataLocation)
                .appendingPathComponent("control.sock")
        )
        do {
            async let currentBind = control.configValue(key: "bind")
            async let currentMDNS = control.configValue(key: "advertise_mdns")
            let (bind, mdns) = try await (currentBind, currentMDNS)
            let needsUpdate = bind != desiredBind || mdns != desiredMDNS
            guard needsUpdate else { return }
            try await control.setConfig(key: "bind", value: desiredBind)
            try await control.setConfig(
                key: "advertise_mdns",
                value: desiredMDNS
            )
            await hubService.ensureCompatibleHelper(
                dataLocation: syncPreferences.dataLocation
            )
        } catch {
            hubService.errorMessage = "The local server's network visibility "
                + "could not be applied: \(error.localizedDescription)"
        }
    }

    /// Imports initial paths through the same HTTPS admin API used by the rest
    /// of the app. The control socket has already completed trust bootstrap.
    private func importInitialFoldersAndSync(
        paths: [String],
        into runtime: LibraryRuntime
    ) async {
        await hubService.ensureCompatibleHelper(
            dataLocation: syncPreferences.dataLocation
        )
        guard hubService.isEnabled, !syncPreferences.dataLocation.isEmpty else {
            return
        }
        guard let profile = profileRegistry.activeProfile,
              let connection = LibraryServerConnection.resolve(
                profile: profile,
                operations: runtime.syncOperationStore,
                deviceID: runtime.database.deviceID,
                localAdminToken: syncPreferences.localAdminToken
              ),
              connection.isLocallyHosted else { return }
        for path in paths {
            _ = try? await connection.client.addAdminFolder(path: path)
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
            // deleted below. When this is the final profile, replace it with
            // a neutral empty runtime; removing the registry entry below then
            // makes Settings render the same setup flow as first launch.
            let fallback = profileRegistry.profiles.first {
                $0.id != profile.id && $0.kind == .local
            } ?? profileRegistry.profiles
                .filter { $0.id != profile.id }
                .max { $0.lastActivatedAt < $1.lastActivatedAt }
            if let fallback {
                activateProfile(fallback)
            } else {
                runtime.playbackController.stopAndClear()
                let replacement = LibraryRuntime(
                    databaseURL: LibraryDatabase.defaultURL(),
                    playbackPreferences: playbackPreferences,
                    audioDeviceManager: audioDeviceManager,
                    profile: nil,
                    localAdminToken: syncPreferences.localAdminToken
                )
                replacement.libraryStore.selection = .settings
                runtime = replacement
                nowPlayingCoordinator.rebind(
                    to: replacement.playbackController
                )
            }
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
        guard let profile = profileRegistry.activeProfile,
              let hash = song.contentHash,
              let connection = LibraryServerConnection.resolve(
                profile: profile,
                operations: runtime.syncOperationStore,
                deviceID: runtime.database.deviceID,
                localAdminToken: syncPreferences.localAdminToken
              ) else {
            throw AroSyncClientError.invalidResponse
        }
        _ = try await connection.client.removeTrack(
            contentHash: hash,
            credential: connection.credential
        )
        runtime.libraryStore.reflectServerRemoval(trackID: song.libraryID)
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
