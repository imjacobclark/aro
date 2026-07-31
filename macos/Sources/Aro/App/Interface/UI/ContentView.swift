import AppKit
import AroCommon
import OSLog
import SwiftUI

/// Disk-backed last-known-good cache for `ContentView`'s `cachedPlaylists`/
/// `cachedRemoteHubInfo`, keyed per profile. `ContentView`'s own `@State` (see its
/// doc comment) already gives Home/Metadata a stale-while-revalidate feel *within* a
/// running session, but resets to empty on every fresh app launch since in-memory
/// state doesn't survive process exit — the first launch after any restart still
/// shows the empty/false-negative state until the network round trip completes. This
/// persists the same values to `UserDefaults` so a fresh launch has something to show
/// immediately too, revalidated in the background exactly as within a session.
@MainActor
private enum ScreenDataCache {
    private static let defaults = UserDefaults.standard

    private static func key(_ prefix: String, _ profileID: UUID?) -> String? {
        guard let profileID else { return nil }
        return "\(prefix).\(profileID.uuidString)"
    }

    static func playlists(for profileID: UUID?) -> [ServerGeneratedPlaylist] {
        guard let key = key("screenCache.playlists", profileID),
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ServerGeneratedPlaylist].self, from: data)
        else { return [] }
        return decoded
    }

    static func savePlaylists(_ playlists: [ServerGeneratedPlaylist], for profileID: UUID?) {
        guard let key = key("screenCache.playlists", profileID),
              let data = try? JSONEncoder().encode(playlists)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func hubInfo(for profileID: UUID?) -> AroHubInfo? {
        guard let key = key("screenCache.hubInfo", profileID),
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AroHubInfo.self, from: data)
        else { return nil }
        return decoded
    }

    static func saveHubInfo(_ hubInfo: AroHubInfo?, for profileID: UUID?) {
        guard let key = key("screenCache.hubInfo", profileID) else { return }
        guard let hubInfo, let data = try? JSONEncoder().encode(hubInfo) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

struct ContentView: View {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "RemoteSync"
    )

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
    @State private var importError: String?
    @State private var syncDataStatus: String?
    @State private var isSynchronizingRemoteLibrary = false
    @State private var canContributeToActiveRemote = false
    @State private var identificationLocalServers = LocalAroServerMonitor()
    @State private var spacebarMonitor: Any?
    /// Held here, not inside `HomeView`/`MetadataView`, because those views are
    /// torn down and rebuilt every time the sidebar selection moves away and
    /// back (see the `if/else if` content switcher below) — a view-local `@State`
    /// would reset to empty on every revisit and force a blank/false-negative
    /// flash until the next network round trip finishes. `ContentView` itself
    /// isn't recreated by a `store.selection` change, so these survive
    /// navigation and give both screens a stale-while-revalidate feel: last
    /// known data renders immediately, refreshed quietly in the background.
    @State private var cachedPlaylists: [ServerGeneratedPlaylist] = []
    @State private var cachedIdentificationStatus: IdentificationStatus?
    @State private var cachedRemoteHubInfo: AroHubInfo?

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
                        loadRadio: { contentHash in
                            await homePlaylistsBridge.radio(contentHash: contentHash)
                        },
                        removeSong: removeSong,
                        syncTrackData: syncTrackData,
                        playlists: $cachedPlaylists
                    )
                } else if store.selection == .artists {
                    ArtistsView(
                        songs: store.allSongs,
                        playback: playback,
                        syncTrackData: syncTrackData,
                        loadRadio: { contentHash in
                            await homePlaylistsBridge.radio(contentHash: contentHash)
                        }
                    )
                } else if store.selection == .albums {
                    AlbumsView(
                        songs: store.allSongs,
                        playback: playback,
                        syncTrackData: syncTrackData,
                        syncAlbumData: syncAlbumData,
                        loadRadio: { contentHash in
                            await homePlaylistsBridge.radio(contentHash: contentHash)
                        }
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
                        syncStore: syncStore,
                        status: $cachedIdentificationStatus,
                        remoteHubInfo: $cachedRemoteHubInfo
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
                        syncTrackData: syncTrackData,
                        loadRadio: { contentHash in
                            await homePlaylistsBridge.radio(contentHash: contentHash)
                        },
                        allSongs: store.allSongs
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
            playback.reconcileAvailableSongs(store.allSongs)
        }
        .onChange(of: cachedPlaylists) { _, newValue in
            ScreenDataCache.savePlaylists(newValue, for: profileRegistry.activeProfileID)
        }
        .onChange(of: cachedRemoteHubInfo) { _, newValue in
            ScreenDataCache.saveHubInfo(newValue, for: profileRegistry.activeProfileID)
        }
        .task(id: profileRegistry.activeProfileID) {
            canContributeToActiveRemote = false
            // A profile switch points Home/Metadata at a different library entirely --
            // the previous profile's cached playlists/queue status/hub info must not
            // linger and render as if they belonged to the new one. Re-seed from this
            // profile's own persisted cache (if any) rather than blanking to empty, so
            // switching profiles gets the same stale-while-revalidate treatment as a
            // fresh launch instead of a guaranteed empty-state flash.
            cachedPlaylists = ScreenDataCache.playlists(for: profileRegistry.activeProfileID)
            cachedIdentificationStatus = nil
            cachedRemoteHubInfo = ScreenDataCache.hubInfo(for: profileRegistry.activeProfileID)
            while !Task.isCancelled {
                if let profile = profileRegistry.activeProfile,
                   profile.kind == .remote {
                    let started = ContinuousClock.now
                    await synchronizeRemoteLibrary(profile)
                    Self.logger.debug(
                        "remote sync loop tick finished in \(started.duration(to: .now).formatted(), privacy: .public)"
                    )
                } else {
                    Self.logger.debug(
                        "remote sync loop tick skipped: active profile is not remote"
                    )
                }
                try? await Task.sleep(for: .seconds(30))
            }
            Self.logger.warning("remote sync loop exited (task cancelled)")
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
        // Every branch of this guard used to fail completely silently — no log, no
        // UI feedback — which made a stuck `isSynchronizingRemoteLibrary` flag (or
        // any other precondition failure) indistinguishable from "nothing new to
        // sync" from the outside. Logging which specific condition failed turns a
        // silent no-op into something diagnosable.
        guard !isSynchronizingRemoteLibrary else {
            Self.logger.warning(
                "synchronizeRemoteLibrary skipped: already in progress (isSynchronizingRemoteLibrary stuck true?)"
            )
            return
        }
        guard let hubID = profile.hubID else {
            Self.logger.warning("synchronizeRemoteLibrary skipped: profile has no hubID")
            return
        }
        guard let baseURL = profile.baseURL else {
            Self.logger.warning("synchronizeRemoteLibrary skipped: profile has no baseURL")
            return
        }
        guard let membership = syncStore.membership(baseURL: baseURL) else {
            Self.logger.warning(
                "synchronizeRemoteLibrary skipped: no stored membership for \(baseURL.absoluteString, privacy: .public)"
            )
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
            // Resolved rather than used as stored — the recorded Bonjour hostname can
            // point at advertised-but-unroutable addresses, and picking one costs a
            // full request timeout. See `HubEndpointResolver`.
            let endpoint = await HubEndpointResolver.resolve(
                storedBaseURL: baseURL,
                hubID: hubID,
                tlsFingerprint: membership.tlsFingerprint
            )
            let result = try await HubSyncCoordinator(
                hubID: hubID,
                client: AroSyncClient(
                    baseURL: endpoint,
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
            // Drop the pinned endpoint so the next attempt re-probes from scratch.
            // An address that worked before means nothing after a network change (or
            // a hub that moved), and without this a cached-but-now-dead endpoint
            // would be retried first every time, reintroducing exactly the timeout
            // this resolver exists to avoid.
            HubEndpointResolver.invalidate(hubID: hubID)
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
        guard let remote = await remoteSyncContext else { return nil }
        return try? await remote.client.downloadBlob(
            hash: hash,
            from: 0,
            credential: remote.credential
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

        // Imported through the local hub (its `SourceManager`), not this app's
        // own scanner: the hub already does managed-mode copying, hashing, and
        // watching -- `ManagedMusicImporter`/`watchManagedSource` duplicated
        // exactly that, client-side, for folders added this way. See
        // `AroApp.importInitialFoldersAndSync`, which does the same thing for
        // a profile's initial folders.
        let mode: HubImportMode = profileRegistry.activeProfile?.managedMusicPath == nil
            ? .referenced
            : .managed
        importStatus = "Importing music…"
        Task {
            do {
                await hubService.ensureCompatibleHelper(
                    dataLocation: syncPreferences.dataLocation
                )
                guard hubService.isEnabled, !syncPreferences.dataLocation.isEmpty else {
                    importStatus = nil
                    importError =
                        "Aro couldn't reach the Background Service to import this folder."
                    return
                }
                let control = HubControlClient(
                    socketURL: URL(fileURLWithPath: syncPreferences.dataLocation)
                        .appendingPathComponent("control.sock")
                )
                let imported = try await control.importFolder(
                    path: url.path,
                    mode: mode
                )
                if let status = try? await control.status() {
                    let coordinator = LocalHubReplicaCoordinator(
                        hubID: status.hubID,
                        client: control,
                        operations: syncStore
                    )
                    _ = try? await coordinator.synchronize()
                    store.refreshFoldersFromDatabase()
                }
                importStatus = "Imported \(imported) files"
                try? await Task.sleep(for: .seconds(3))
                importStatus = nil
            } catch {
                importStatus = nil
                importError = error.localizedDescription
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

    /// Pulls the active hub's identification results (title/artist/album/artwork URL/
    /// genres/moods) and merges them into this app's own catalog by content hash.
    ///
    /// Identification results deliberately live outside the CRDT operation log, so
    /// unlike track metadata they never arrive via `exchange` — they have to be pulled
    /// explicitly, over whichever transport actually reaches the active hub. A remote
    /// profile has no local control socket to *its* hub, so before this routed by
    /// profile kind it silently pulled nothing at all for remote libraries, stranding
    /// hub-side Cover Art Archive artwork: any track without embedded art stayed on
    /// the placeholder cover permanently.
    private func pullIdentificationResults() async {
        if let remote = await remoteSyncContext {
            await pullIdentificationResults(
                hubKey: remote.hubID.uuidString,
                fetch: { after in
                    try? await remote.client.identificationResults(
                        after: after,
                        credential: remote.credential
                    )
                },
                blob: { hash in
                    try? await remote.client.downloadBlob(
                        hash: hash,
                        from: 0,
                        credential: remote.credential
                    )
                }
            )
            return
        }

        identificationLocalServers.refresh()
        guard let client = identificationControlClient else { return }
        await pullIdentificationResults(
            hubKey: "local",
            fetch: { after in try? await client.identificationResults(after: after) },
            blob: { hash in try? await client.blob(hash: hash) }
        )
    }

    private func pullIdentificationResults(
        hubKey: String,
        fetch: (Int64) async -> [IdentificationResult]?,
        blob: @escaping (String) async -> Data?
    ) async {
        // Keyed per hub: a local hub and a remote hub each stamp `identifiedAt` from
        // their own clock over their own independent set of results, so a single
        // shared cursor would let whichever hub is behind skip everything the other
        // had already advanced past.
        let cursorKey = "\(Self.lastAppliedIdentificationKey).\(hubKey)"
        let after = Int64(UserDefaults.standard.integer(forKey: cursorKey))
        guard let results = await fetch(after), !results.isEmpty else { return }
        await store.applyIdentificationResults(results, resolveBlobHash: blob)
        if let newest = results.map(\.identifiedAt).max() {
            UserDefaults.standard.set(Int(newest), forKey: cursorKey)
        }
    }

    /// The active profile's remote hub client plus the credential it authenticates
    /// with — `nil` whenever this Mac is hosting its own library rather than acting as
    /// a client of someone else's.
    ///
    /// The base URL is resolved to a *reachable* endpoint rather than used as stored:
    /// the stored Bonjour hostname can resolve to advertised-but-dead addresses, which
    /// cost a full request timeout each time one is picked. See `HubEndpointResolver`.
    private var remoteSyncContext: (
        client: AroSyncClient,
        credential: HubDeviceCredential,
        hubID: UUID
    )? {
        get async {
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
            let endpoint = await HubEndpointResolver.resolve(
                storedBaseURL: baseURL,
                hubID: hubID,
                tlsFingerprint: membership.tlsFingerprint
            )
            return (
                AroSyncClient(
                    baseURL: endpoint,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                ),
                credential,
                hubID
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
