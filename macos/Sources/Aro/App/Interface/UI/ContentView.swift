import AppKit
import AroCommon
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    let playback: PlaybackController
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: AudioDeviceManager
    @Bindable var profileRegistry: LibraryProfileRegistry
    @Bindable var hubService: AroHubService
    @Bindable var syncPreferences: SyncPreferences
    @Bindable var mediaCache: MediaCacheController
    let libraryFiles: any LibraryFileManaging
    let reviewLibraryHealth: ReviewLibraryHealth
    let loadStatsDashboard: LoadStatsDashboard
    let syncStore: SQLiteSyncOperationStore
    let removeSong: (Song) async throws -> Void
    let setSongFavourite: (Song, Bool) async throws -> Void
    let activateProfile: (LibraryProfile) -> Void
    let forgetProfile: (LibraryProfile) -> Void
    let completeRemoteConnection: (
        AroHubInfo,
        URL,
        String,
        OfflineDownloadPolicy
    ) -> Void
    @State private var importStatus: String?
    @State private var managedSourceMonitors: [String: FolderMonitor] = [:]
    @State private var importError: String?
    @State private var syncDataStatus: String?
    @State private var isSynchronizingRemoteLibrary = false
    @State private var canContributeToActiveRemote = false
    @State private var identificationLocalServers = LocalAroServerMonitor()
    @State private var spacebarMonitor: Any?

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                NavigationSidebar(
                    selection: $store.selection,
                    folders: store.folders,
                    scanStates: store.scanStates,
                    canAddSync: !addSyncIsDisabled,
                    addSyncHelp: addSyncIsDisabled
                        ? "This device isn't allowed to add music to "
                            + "\(profileRegistry.activeProfile?.name ?? "this library"). "
                            + "Ask its owner to enable contributions."
                        : "Add a folder to sync",
                    canRemoveSyncs:
                        profileRegistry.activeProfile?.kind != .remote,
                    addSync: chooseFolder,
                    removeSync: { removeFolder(id: $0) }
                )
                .frame(width: 240)

                Rectangle()
                    .fill(AroTheme.hairline)
                    .frame(width: 1)

                Group {
                if store.selection == .home {
                    HomeView(
                        allSongs: { store.allSongs },
                        playback: playback,
                        mediaCache: mediaCache,
                        usesStreamOnlyIcon:
                            profileRegistry.activeProfile?.offlinePolicy
                                == .streamOnly,
                        storesLibraryCopy:
                            profileRegistry.activeProfile?.managedMusicPath != nil,
                        loadPlaylists: {
                            identificationLocalServers.refresh()
                            return await homePlaylistsBridge.playlists()
                        },
                        removeSong: removeSong,
                        syncTrackData: syncTrackData
                    )
                } else if store.selection == .artists {
                    ArtistsView(
                        songs: store.allSongs,
                        playback: playback,
                        syncTrackData: syncTrackData
                    )
                } else if store.selection == .albums {
                    AlbumsView(
                        songs: store.allSongs,
                        playback: playback,
                        syncTrackData: syncTrackData,
                        syncAlbumData: syncAlbumData
                    )
                } else if store.selection == .stats {
                    StatsView(
                        playback: playback,
                        loadStatsDashboard: loadStatsDashboard
                    )
                } else if store.selection == .libraryHealth {
                    LibraryHealthView(
                        reviewLibraryHealth: reviewLibraryHealth
                    )
                } else if store.selection == .settings {
                    LibrarySettingsView(
                        library: store,
                        registry: profileRegistry,
                        service: hubService,
                        preferences: syncPreferences,
                        mediaCache: mediaCache,
                        syncStore: syncStore,
                        libraryFiles: libraryFiles,
                        activateProfile: activateProfile,
                        forgetProfile: forgetProfile,
                        completeRemoteConnection: completeRemoteConnection
                    )
                } else if store.selection == .metadata {
                    MetadataView(
                        songs: store.allSongs,
                        preferences: syncPreferences,
                        profileRegistry: profileRegistry,
                        syncStore: syncStore
                    )
                } else if case .folder(let folderID) = store.selection,
                          let folder = store.folders.first(where: {
                              $0.id == folderID
                          }),
                          !folder.isAccessible {
                    MissingSyncView(
                        folder: folder,
                        onLocate: {
                            locateFolder(id: folder.id)
                        },
                        onStopWatching: {
                            removeFolder(id: folder.id)
                        }
                    )
                } else {
                    SongTableView(
                        title: store.selectedTitle,
                        songs: store.visibleSongs,
                        scanState: store.selectedScanState,
                        hasWatchedFolders: !store.folders.isEmpty,
                        playback: playback,
                        mediaCache: mediaCache,
                        usesStreamOnlyIcon:
                            profileRegistry.activeProfile?.offlinePolicy
                                == .streamOnly,
                        storesLibraryCopy:
                            profileRegistry.activeProfile?.managedMusicPath != nil,
                        removeSong: removeSong,
                        syncTrackData: syncTrackData
                    )
                }
                }
                // Reserve room at the bottom so scrollable content can clear the
                // floating player without putting footer content in the
                // intentionally empty lower half of the navigation sidebar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 112)
                }
                .background(AroTheme.contentSurface)
                }

            // Last in the ZStack, so the bar floats above everything else.
            PlayerBar(
                playback: playback,
                preferences: preferences,
                deviceManager: deviceManager,
                setFavourite: setSongFavourite
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .task {
            store.start()
            playback.reconcileAvailableSongs(store.allSongs)
            startManagedSourceMonitors()
        }
        .task(id: profileRegistry.activeProfileID) {
            canContributeToActiveRemote = false
            while !Task.isCancelled {
                if let profile = profileRegistry.activeProfile,
                   profile.kind == .remote {
                    await synchronizeRemoteLibrary(profile)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task {
            // aro-server's identification results land in its own hub.sqlite3, not
            // this app's local library catalog — this loop is the bridge, pulling
            // new results by content hash and merging them in. Runs regardless of
            // host/remote profile kind: it only ever needs the local control socket.
            while !Task.isCancelled {
                await pullIdentificationResults()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task {
            // Complements the pull above: on a pure remote client (no local
            // aro-server actually running identification), title/artist/album/
            // artwork only ever arrive via normal CRDT sync — which carries the
            // artwork URL but not the image bytes. This downloads them separately.
            while !Task.isCancelled {
                await store.downloadPendingArtwork(resolveBlobHash: resolveRemoteArtworkBlob)
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: store.allSongs.map(\.id)) {
            playback.reconcileAvailableSongs(store.allSongs)
        }
        .onAppear {
            installSpacebarMonitor()
        }
        .onDisappear {
            removeSpacebarMonitor()
        }
        .overlay(alignment: .top) {
            if let importStatus {
                Label(importStatus, systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
            } else if let syncDataStatus {
                Label(syncDataStatus, systemImage: "arrow.triangle.2.circlepath")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
        .alert(
            "Unable to Import Music",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    private func synchronizeRemoteLibrary(_ profile: LibraryProfile) async {
        guard !isSynchronizingRemoteLibrary,
              let hubID = profile.hubID,
              let baseURL = profile.baseURL,
              let membership = syncStore.membership(baseURL: baseURL) else {
            return
        }
        isSynchronizingRemoteLibrary = true
        defer { isSynchronizingRemoteLibrary = false }
        syncStore.recordSyncStarted(hubID: hubID)
        do {
            guard let credential = try FileHubCredentialStore().load(
                hubID: hubID,
                deviceID: libraryDeviceID
            ) else {
                throw HubCredentialError.missingRecord
            }
            let result = try await HubSyncCoordinator(
                hubID: hubID,
                client: AroSyncClient(
                    baseURL: baseURL,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                ),
                credential: credential,
                operations: syncStore,
                offlineTrackCount: UInt64(mediaCache.downloadedFileCount),
                sourceMode: profile.managedMusicPath == nil
                    ? "referenced"
                    : "managed"
            ).synchronize()
            syncStore.recordSyncSucceeded(hubID: hubID, result: result)
            canContributeToActiveRemote = result.canContribute
            store.reloadStoredLibrary()
            await mediaCache.apply(
                profile.offlinePolicy,
                storageLimitBytes: profile.storageLimitBytes
            )
        } catch {
            syncStore.recordSyncFailed(
                hubID: hubID,
                message: error.localizedDescription
            )
            // The full history is always available in Devices via
            // `syncStore.syncStatus`; this is just a transient heads-up for
            // whoever happens to be looking at this screen when it fails.
            syncDataStatus = "Library sync failed: \(error.localizedDescription)"
            try? await Task.sleep(for: .seconds(5))
            syncDataStatus = nil
        }
    }

    /// Fetches a cached-artwork blob from a *remote* hub — authenticated with this
    /// device's paired credential and the pinned TLS fingerprint recorded at join
    /// time, the same trust path `synchronizeRemoteLibrary` above already uses.
    /// Needed because the hub's `/v1/blobs/{hash}` HTTP endpoint (unlike the local
    /// control socket `pullIdentificationResults` uses) requires both.
    private func resolveRemoteArtworkBlob(hash: String) async -> Data? {
        guard let profile = profileRegistry.activeProfile,
              profile.kind == .remote,
              let hubID = profile.hubID,
              let baseURL = profile.baseURL,
              let membership = syncStore.membership(baseURL: baseURL),
              let credential = try? FileHubCredentialStore().load(
                hubID: hubID,
                deviceID: libraryDeviceID
              )
        else {
            return nil
        }
        let client = AroSyncClient(
            baseURL: baseURL,
            pinnedTLSFingerprint: membership.tlsFingerprint
        )
        return try? await client.downloadBlob(
            hash: hash,
            from: 0,
            credential: credential
        )
    }

    private var addSyncIsDisabled: Bool {
        profileRegistry.activeProfile?.kind == .remote && !canContributeToActiveRemote
    }

    private var libraryDeviceID: UUID {
        UserDefaults.standard.string(forKey: "library.deviceID")
            .flatMap(UUID.init(uuidString:))
            ?? UUID()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Sync"
        panel.prompt = "Sync Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if let managedPath = profileRegistry.activeProfile?.managedMusicPath {
            importStatus = "Importing music…"
            Task {
                do {
                    let destination = URL(fileURLWithPath: managedPath)
                    let result = try await ManagedMusicImporter().importFolder(
                        url,
                        into: destination
                    )
                    store.addFolder(destination)
                    if var profile = profileRegistry.activeProfile,
                       !profile.referencedMusicPaths.contains(url.path) {
                        profile.referencedMusicPaths.append(url.path)
                        profileRegistry.update(profile)
                    }
                    watchManagedSource(url, destination: destination)
                    importStatus = "Imported \(result.importedFiles) files"
                    try? await Task.sleep(for: .seconds(3))
                    importStatus = nil
                } catch {
                    importStatus = nil
                    importError = error.localizedDescription
                }
            }
        } else {
            store.addFolder(url)
        }
    }

    private func startManagedSourceMonitors() {
        guard let profile = profileRegistry.activeProfile,
              let managedPath = profile.managedMusicPath else { return }
        let destination = URL(fileURLWithPath: managedPath)
        for path in profile.referencedMusicPaths {
            watchManagedSource(
                URL(fileURLWithPath: path),
                destination: destination
            )
        }
    }

    private func watchManagedSource(_ source: URL, destination: URL) {
        guard managedSourceMonitors[source.path] == nil else { return }
        managedSourceMonitors[source.path] = FolderMonitor(url: source) {
            Task {
                _ = try? await ManagedMusicImporter().importFolder(
                    source,
                    into: destination
                )
            }
        }
    }

    private func locateFolder(id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Locate Sync Folder"
        panel.message = "Choose the folder’s new location."
        panel.prompt = "Locate"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        store.relocateFolder(id: id, to: url)
    }

    /// True for the one Sync that is this Mac's managed library folder — the
    /// canonical store `aro-server` actually shares from when sharing is on,
    /// as opposed to an arbitrary externally-watched folder.
    private func isHostLibraryFolder(_ folder: WatchedFolder) -> Bool {
        guard let managedMusicPath = profileRegistry.activeProfile?.managedMusicPath else {
            return false
        }
        return folder.url.path == managedMusicPath
    }

    /// Spacebar play/pause, scoped so it never steals Space from text entry
    /// (search fields, folder rename, etc.) or from a table's own type-ahead
    /// handling — only intercepts when nothing text-editable has focus.
    private func installSpacebarMonitor() {
        guard spacebarMonitor == nil else { return }
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49 else {
                return event
            }
            if let responder = NSApp.keyWindow?.firstResponder,
               isTextEntryResponder(responder) {
                return event
            }
            playback.togglePlayPause()
            return nil
        }
    }

    private func removeSpacebarMonitor() {
        if let spacebarMonitor {
            NSEvent.removeMonitor(spacebarMonitor)
        }
        spacebarMonitor = nil
    }

    private func isTextEntryResponder(_ responder: NSResponder) -> Bool {
        responder is NSTextView
            || responder is NSTextField
            || responder is NSSearchField
    }

    private func removeFolder(id: UUID) {
        playback.reconcileAvailableSongs(
            store.songsExcludingFolder(id: id)
        )
        store.removeFolder(id: id)
    }

    /// Local-or-remote transport for triggering identification — see
    /// `IdentificationSyncBridge`'s doc comment for why a pure remote client (no
    /// locally-hosted `aro-server`) needs a different path than the local control
    /// socket `identificationControlClient` below uses.
    private var identificationSyncBridge: IdentificationSyncBridge {
        IdentificationSyncBridge(
            dataLocation: syncPreferences.dataLocation,
            localServers: identificationLocalServers.servers,
            remoteProfile: profileRegistry.activeProfile,
            syncStore: syncStore,
            libraryDeviceID: libraryDeviceID
        )
    }

    /// Same local-or-remote transport split as `identificationSyncBridge`, for the Home
    /// screen's server-generated playlists.
    private var homePlaylistsBridge: HomePlaylistsBridge {
        HomePlaylistsBridge(
            dataLocation: syncPreferences.dataLocation,
            localServers: identificationLocalServers.servers,
            remoteProfile: profileRegistry.activeProfile,
            syncStore: syncStore,
            libraryDeviceID: libraryDeviceID
        )
    }

    private var identificationControlClient: HubControlClient? {
        let dataLocation = LibrarySettingsView.controlDataLocation(
            preferred: syncPreferences.dataLocation,
            servers: identificationLocalServers.servers
        )
        guard let dataLocation, !dataLocation.isEmpty else { return nil }
        return HubControlClient(
            socketURL: URL(fileURLWithPath: dataLocation)
                .appendingPathComponent("control.sock")
        )
    }

    /// "Sync Track Data": right-click action that (re-)enqueues one track for
    /// background AcoustID/MusicBrainz identification. Addressed by content hash (and,
    /// for a self-hosted server, path) — not `song.libraryID`, which is local to this
    /// app's own catalog and aro-server has never heard of it.
    private func syncTrackData(_ song: Song) async {
        identificationLocalServers.refresh()
        do {
            let queued = try await identificationSyncBridge.identify([song])
            syncDataStatus = queued > 0
                ? "Queued for identification"
                : "Already up to date"
        } catch {
            syncDataStatus = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(3))
        syncDataStatus = nil
    }

    /// "Sync Album Data": same, for every track in the album at once.
    private func syncAlbumData(_ songs: [Song]) async {
        identificationLocalServers.refresh()
        do {
            let queued = try await identificationSyncBridge.identify(songs)
            syncDataStatus = queued > 0
                ? "Queued \(queued) of \(songs.count) song(s) for identification"
                : "Already up to date"
        } catch {
            syncDataStatus = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(3))
        syncDataStatus = nil
    }

    private static let lastAppliedIdentificationKey = "identification.lastAppliedAt"

    private func pullIdentificationResults() async {
        identificationLocalServers.refresh()
        guard let client = identificationControlClient else { return }
        let after = Int64(
            UserDefaults.standard.integer(forKey: Self.lastAppliedIdentificationKey)
        )
        guard let results = try? await client.identificationResults(after: after),
              !results.isEmpty else {
            return
        }
        await store.applyIdentificationResults(results) { hash in
            try? await client.blob(hash: hash)
        }
        if let newest = results.map(\.identifiedAt).max() {
            UserDefaults.standard.set(
                Int(newest),
                forKey: Self.lastAppliedIdentificationKey
            )
        }
    }
}

private struct MissingSyncView: View {
    let folder: WatchedFolder
    let onLocate: () -> Void
    let onStopWatching: () -> Void
    @State private var confirmsStopWatching = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text("Sync Folder Not Found")
                .font(.title2.weight(.semibold))

            Text(
                "This folder no longer exists locally. If you moved it, "
                    + "select Locate below to find its new location. "
                    + "Otherwise, stop watching it. Music already synced "
                    + "into Aro will remain in Aro."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

            Text(folder.url.path)
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(2)

            HStack(spacing: 10) {
                Button("Locate…", action: onLocate)
                    .buttonStyle(.borderedProminent)

                Button("Stop Watching", role: .destructive) {
                    confirmsStopWatching = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .alert(
            "Stop Watching “\(folder.displayName)”?",
            isPresented: $confirmsStopWatching
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Watching", role: .destructive) {
                onStopWatching()
            }
        } message: {
            Text(
                "Aro will stop checking this folder. Music already "
                    + "synced into Aro will remain in Aro."
            )
        }
    }
}
