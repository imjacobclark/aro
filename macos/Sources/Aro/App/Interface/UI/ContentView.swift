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
/// persists the same values in the active library's SQLite cache so a fresh launch
/// and a fully offline session have a durable server-authored read model.
@MainActor
private enum ScreenDataCache {
    private static func key(_ prefix: String, _ profileID: UUID?) -> String? {
        guard let profileID else { return nil }
        return "\(prefix).\(profileID.uuidString)"
    }

    static func playlists(
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) -> [ServerGeneratedPlaylist] {
        guard let key = key("playlists", profileID) else { return [] }
        return store.cachedServerSnapshot(key, as: [ServerGeneratedPlaylist].self) ?? []
    }

    static func savePlaylists(
        _ playlists: [ServerGeneratedPlaylist],
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) {
        guard let key = key("playlists", profileID) else { return }
        store.saveServerSnapshot(playlists, key: key)
    }

    static func hubInfo(
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) -> AroHubInfo? {
        guard let key = key("hubInfo", profileID) else { return nil }
        return store.cachedServerSnapshot(key, as: AroHubInfo.self)
    }

    static func saveHubInfo(
        _ hubInfo: AroHubInfo?,
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) {
        guard let key = key("hubInfo", profileID), let hubInfo else { return }
        store.saveServerSnapshot(hubInfo, key: key)
    }

    static func catalog(
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) -> CatalogPage? {
        guard let key = key("catalog", profileID) else { return nil }
        return store.cachedServerSnapshot(key, as: CatalogPage.self)
    }

    static func saveCatalog(
        _ page: CatalogPage,
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) {
        guard let key = key("catalog", profileID) else { return }
        store.saveServerSnapshot(page, key: key)
    }

    static func stats(
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) -> StatsDashboard? {
        guard let key = key("stats", profileID) else { return nil }
        return store.cachedServerSnapshot(key, as: StatsDashboard.self)
    }

    static func saveStats(
        _ dashboard: StatsDashboard,
        for profileID: UUID?,
        store: SQLiteSyncOperationStore
    ) {
        guard let key = key("stats", profileID) else { return }
        store.saveServerSnapshot(dashboard, key: key)
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
    @State private var cachedCatalogPage: CatalogPage?
    @State private var cachedStatsDashboard: StatsDashboard?
    @State private var metadataEditorContext: MetadataEditorContext?

    /// Kept outside the root navigation switch so Swift can type-check clean
    /// builds without having to solve every destination and Home's closures as
    /// one giant SwiftUI expression.
    private var homeContent: some View {
        HomeView(
            allSongs: { store.allSongs },
            playback: playback,
            mediaCache: mediaCache,
            usesStreamOnlyIcon:
                profileRegistry.activeProfile?.offlinePolicy == .streamOnly,
            storesLibraryCopy:
                profileRegistry.activeProfile?.managedMusicPath != nil,
            loadPlaylists: {
                return await homePlaylistsBridge.playlists()
            },
            loadRadio: { contentHash in
                await homePlaylistsBridge.radio(contentHash: contentHash)
            },
            removeSong: removeSong,
            syncTrackData: syncTrackData,
            editMetadata: { song in
                metadataEditorContext = MetadataEditorContext(
                    scope: .track,
                    songs: [song]
                )
            },
            playlists: $cachedPlaylists
        )
    }

    @ViewBuilder
    private var selectedContent: some View {
        if store.selection == .home {
            homeContent
        } else if store.selection == .artists {
            ArtistsView(
                songs: store.allSongs,
                playback: playback,
                syncTrackData: syncTrackData,
                editMetadata: { metadataEditorContext = $0 },
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
                editMetadata: { metadataEditorContext = $0 },
                loadRadio: { contentHash in
                    await homePlaylistsBridge.radio(contentHash: contentHash)
                }
            )
        } else if store.selection == .stats {
            StatsView(
                playback: playback,
                loadStatsDashboard: loadStatsDashboard,
                serverDashboard: cachedStatsDashboard
            )
        } else if store.selection == .libraryHealth {
            LibraryHealthView(reviewLibraryHealth: reviewLibraryHealth)
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
                completeRemoteConnection: completeRemoteConnection,
                planTranscode: { quality in
                    guard let remote = await remoteSyncContext else { return nil }
                    return try? await remote.client.transcodePlan(
                        quality: quality,
                        credential: remote.credential
                    )
                },
                startTranscode: { quality in
                    guard let remote = await remoteSyncContext else { return nil }
                    return try? await remote.client.startTranscode(
                        quality: quality,
                        credential: remote.credential
                    )
                },
                transcodeProgress: { jobID in
                    guard let remote = await remoteSyncContext else { return nil }
                    return try? await remote.client.jobStatus(
                        jobID: jobID,
                        credential: remote.credential
                    )
                },
                cleanupTranscodes: { quality in
                    guard let remote = await remoteSyncContext else { return nil }
                    return try? await remote.client.cleanupTranscodes(
                        keeping: quality,
                        credential: remote.credential
                    )
                },
                transcodeUsage: {
                    guard let remote = await remoteSyncContext else { return [] }
                    return (try? await remote.client.transcodeUsage(
                        credential: remote.credential
                    )) ?? []
                }
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
                  let folder = store.folders.first(where: { $0.id == folderID }),
                  !folder.isAccessible {
            MissingSyncView(
                folder: folder,
                onLocate: { locateFolder(id: folder.id) },
                onStopWatching: { removeFolder(id: folder.id) }
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
                    profileRegistry.activeProfile?.offlinePolicy == .streamOnly,
                storesLibraryCopy:
                    profileRegistry.activeProfile?.managedMusicPath != nil,
                removeSong: removeSong,
                syncTrackData: syncTrackData,
                editMetadata: { song in
                    metadataEditorContext = MetadataEditorContext(
                        scope: .track,
                        songs: [song]
                    )
                },
                loadRadio: { contentHash in
                    await homePlaylistsBridge.radio(contentHash: contentHash)
                },
                allSongs: store.allSongs
            )
        }
    }

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
                    remoteSyncHealth: remoteSyncHealth,
                    addSync: chooseFolder,
                    removeSync: { removeFolder(id: $0) }
                )
                .frame(width: 240)

                Rectangle()
                    .fill(AroTheme.hairline)
                    .frame(width: 1)

                selectedContent
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

            // Topmost, so the sidebar list and content scroll views can't
            // swallow title bar drags and double-clicks. It only hit-tests the
            // title bar strip itself — everything below stays interactive.
            TitleBarInteractionOverlay()
                .ignoresSafeArea()
        }
        .task {
            playback.reconcileAvailableSongs(store.allSongs)
            // Assigned here rather than at construction: the transport depends on
            // the active profile and discovered local servers, which live at this
            // level rather than in `LibraryRuntime`.
            playback.smartShuffleOrder = { hashes, start in
                await homePlaylistsBridge.smartShuffle(
                    contentHashes: hashes,
                    start: start
                )
            }
        }
        .onChange(of: cachedPlaylists) { _, newValue in
            ScreenDataCache.savePlaylists(
                newValue,
                for: profileRegistry.activeProfileID,
                store: syncStore
            )
        }
        .onChange(of: cachedRemoteHubInfo) { _, newValue in
            ScreenDataCache.saveHubInfo(
                newValue,
                for: profileRegistry.activeProfileID,
                store: syncStore
            )
        }
        .task(id: profileRegistry.activeProfileID) {
            canContributeToActiveRemote = false
            playback.restrictsPlaybackToLocalMedia =
                profileRegistry.activeProfile?.kind == .remote
                    && remoteSyncHealth != .online
            // A profile switch points Home/Metadata at a different library entirely --
            // the previous profile's cached playlists/queue status/hub info must not
            // linger and render as if they belonged to the new one. Re-seed from this
            // profile's own persisted cache (if any) rather than blanking to empty, so
            // switching profiles gets the same stale-while-revalidate treatment as a
            // fresh launch instead of a guaranteed empty-state flash.
            cachedPlaylists = ScreenDataCache.playlists(
                for: profileRegistry.activeProfileID,
                store: syncStore
            )
            cachedIdentificationStatus = nil
            cachedRemoteHubInfo = ScreenDataCache.hubInfo(
                for: profileRegistry.activeProfileID,
                store: syncStore
            )
            cachedCatalogPage = ScreenDataCache.catalog(
                for: profileRegistry.activeProfileID,
                store: syncStore
            )
            cachedStatsDashboard = ScreenDataCache.stats(
                for: profileRegistry.activeProfileID,
                store: syncStore
            )
            if let cachedCatalogPage,
               let profile = profileRegistry.activeProfile,
               let baseURL = profile.baseURL {
                store.setServerCatalog(
                    cachedCatalogPage.tracks,
                    baseURL: baseURL,
                    artworkByHash: cachedCatalogArtwork(
                        for: cachedCatalogPage.tracks
                    ),
                    pendingMetadata: syncStore.pendingManualMetadataEdits(),
                    pendingArtwork: syncStore.pendingManualArtworkEdits()
                )
            }
            while !Task.isCancelled {
                if let profile = profileRegistry.activeProfile,
                   profile.hubID != nil,
                   profile.baseURL != nil {
                    let started = ContinuousClock.now
                    await synchronizeServerLibrary(profile)
                    Self.logger.debug(
                        "server sync loop tick finished in \(started.duration(to: .now).formatted(), privacy: .public)"
                    )
                } else {
                    Self.logger.debug(
                        "server sync loop tick skipped: profile is not bound to a server"
                    )
                }
                try? await Task.sleep(for: .seconds(30))
            }
            Self.logger.warning("server sync loop exited (task cancelled)")
        }
        .onChange(of: cachedCatalogPage) { _, newValue in
            if let newValue {
                ScreenDataCache.saveCatalog(
                    newValue,
                    for: profileRegistry.activeProfileID,
                    store: syncStore
                )
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
            store.streamQuality = syncPreferences.streamQuality
        }
        .onChange(of: syncPreferences.streamQuality) { _, quality in
            store.streamQuality = quality
        }
        .onDisappear {
            removeSpacebarMonitor()
        }
        .overlay(alignment: .top) {
            if profileRegistry.activeProfile?.kind == .local,
               let reason = playback.serverUnavailableReason {
                HStack(spacing: 10) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                    Button("Repair & Relaunch Server") {
                        repairLocalServer()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
            } else if let importStatus {
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
        .sheet(item: $metadataEditorContext) { context in
            if let song = context.songs.first {
                MetadataEditorView(
                    context: context,
                    snapshot: store.metadataSnapshot(for: song),
                    save: { edits, artwork in
                        store.applyManualMetadata(
                            edits,
                            artwork: artwork,
                            to: context.songs
                        )
                        syncDataStatus = "Metadata saved; server sync queued"
                    },
                    reset: {
                        store.resetManualMetadata(for: context.songs)
                        syncDataStatus = "Metadata reset; server sync queued"
                    },
                    loadHubArtwork: hubArtworkLoader(for: song),
                    resolveHubArtwork: resolveHubArtwork
                )
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

    private func repairLocalServer() {
        Task {
            syncDataStatus = "Repairing local library server…"
            await hubService.ensureCompatibleHelper(
                dataLocation: syncPreferences.dataLocation
            )
            if let profile = profileRegistry.activeProfile,
               hubService.errorMessage == nil {
                await synchronizeServerLibrary(profile)
            }
            syncDataStatus = hubService.errorMessage
        }
    }

    private func synchronizeServerLibrary(_ profile: LibraryProfile) async {
        guard !isSynchronizingRemoteLibrary else {
            Self.logger.warning(
                "server synchronization skipped: already in progress"
            )
            return
        }
        guard let connection = LibraryServerConnection.resolve(
            profile: profile,
            operations: syncStore,
            deviceID: libraryDeviceID,
            localAdminToken: syncPreferences.localAdminToken
        ) else {
            Self.logger.warning("server synchronization has no authenticated session")
            return
        }
        isSynchronizingRemoteLibrary = true
        defer { isSynchronizingRemoteLibrary = false }
        syncStore.recordSyncStarted(hubID: connection.hubID)
        do {
            let endpoint = connection.isLocallyHosted
                ? connection.baseURL
                : await HubEndpointResolver.resolve(
                    storedBaseURL: connection.baseURL,
                    hubID: connection.hubID,
                    tlsFingerprint: connection.tlsFingerprint
                )
            let client = connection.isLocallyHosted
                ? connection.client
                : AroSyncClient(
                    baseURL: endpoint,
                    pinnedTLSFingerprint: connection.tlsFingerprint
                )
            let result: SyncRunResult
            if !connection.isLocallyHosted,
               profile.offlinePolicy != .streamOnly,
               let credential = connection.credential,
               try await client.deviceAccess(
                    credential: credential
               ).canContribute {
                // Contributors still need the upload portion of full sync for local
                // source blobs. Read-only clients consume only the resolved catalogue.
                result = try await HubSyncCoordinator(
                    hubID: connection.hubID,
                    client: client,
                    credential: credential,
                    operations: syncStore,
                    offlineTrackCount: UInt64(mediaCache.downloadedFileCount),
                    sourceMode: profile.managedMusicPath == nil
                        ? "referenced"
                        : "managed"
                ).synchronize()
            } else {
                let uploaded = try await HubMutationPushCoordinator(
                    hubID: connection.hubID,
                    client: client,
                    credential: connection.credential,
                    operations: syncStore
                ).push()
                result = SyncRunResult(
                    uploadedOperations: uploaded,
                    appliedOperations: 0,
                    cursor: syncStore.serverCursor(hubID: connection.hubID),
                    canContribute: connection.isLocallyHosted
                )
            }
            if let page = try await client.completeCatalogIfChanged(
                from: cachedCatalogPage?.revision,
                credential: connection.credential
            ) {
                cachedCatalogPage = page
                store.setServerCatalog(
                    page.tracks,
                    baseURL: endpoint,
                    artworkByHash: cachedCatalogArtwork(for: page.tracks),
                    pendingMetadata: syncStore.pendingManualMetadataEdits(),
                    pendingArtwork: syncStore.pendingManualArtworkEdits()
                )
                let artwork = await downloadCatalogArtwork(
                    hashes: store.missingServerArtworkHashes(for: page.tracks),
                    client: client,
                    credential: connection.credential
                )
                if !artwork.isEmpty {
                    store.setServerCatalog(
                        page.tracks,
                        baseURL: endpoint,
                        artworkByHash: artwork,
                        pendingMetadata: syncStore.pendingManualMetadataEdits(),
                        pendingArtwork: syncStore.pendingManualArtworkEdits()
                    )
                }
            }
            if let manifest = try? await client.exportManifest(
                credential: connection.credential
            ) {
                syncStore.saveServerSnapshot(
                    manifest,
                    key: "canonicalExportManifest"
                )
            }
            await refreshServerStats(
                client: client,
                credential: connection.credential
            )
            if let sources = try? await client.sourceHealth(
                credential: connection.credential
            ) {
                store.setServerSources(sources)
            }
            syncStore.recordSyncSucceeded(hubID: connection.hubID, result: result)
            canContributeToActiveRemote = result.canContribute
            playback.restrictsPlaybackToLocalMedia = false
            playback.setServerUnavailable(nil)
            if let catalog = cachedCatalogPage?.tracks {
                await mediaCache.apply(
                    profile.offlinePolicy,
                    catalog: catalog,
                    baseURL: endpoint,
                    storageLimitBytes: profile.storageLimitBytes
                )
            }
        } catch {
            if connection.isLocallyHosted {
                playback.setServerUnavailable(
                    "The local library server is unavailable. Aro is attempting to repair it."
                )
                await hubService.ensureCompatibleHelper(
                    dataLocation: syncPreferences.dataLocation
                )
            } else {
                playback.restrictsPlaybackToLocalMedia = true
            }
            syncStore.recordSyncFailed(
                hubID: connection.hubID,
                message: error.localizedDescription
            )
            // Drop the pinned endpoint so the next attempt re-probes from scratch.
            // An address that worked before means nothing after a network change (or
            // a hub that moved), and without this a cached-but-now-dead endpoint
            // would be retried first every time, reintroducing exactly the timeout
            // this resolver exists to avoid.
            if !connection.isLocallyHosted {
                HubEndpointResolver.invalidate(hubID: connection.hubID)
            }
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
    /// Health of the active remote library, derived from the last sync attempt.
    /// `nil` for a locally hosted library, where the sidebar's plain in-sync tick is
    /// already accurate.
    ///
    /// A failed attempt alone isn't treated as an error: if nothing local is waiting
    /// to upload, an unreachable hub means everything we hold is already safely on
    /// the server, which is worth showing as muted rather than alarming. It only
    /// becomes an error once there are local changes stranded here.
    private var remoteSyncHealth: RemoteSyncHealth? {
        guard profileRegistry.activeProfile?.kind == .remote,
              let hubID = profileRegistry.activeProfile?.hubID
        else { return nil }
        guard let status = syncStore.syncStatus(hubID: hubID) else {
            // Paired but never yet synced — treat as not-yet-reachable rather than
            // claiming we're in sync.
            return .offline
        }
        // A sync in flight has already stamped `lastAttemptAt` but not yet
        // `lastSuccessAt`, so treating attempt-newer-than-success as failure would
        // blink the indicator on every poll. Only an actual error counts while a
        // sync is still running.
        let attemptOutranSuccess = !isSynchronizingRemoteLibrary
            && (status.lastSuccessAt == nil
                || (status.lastAttemptAt.map { attempt in
                    status.lastSuccessAt.map { attempt > $0 } ?? true
                } ?? false))
        guard status.lastError != nil || attemptOutranSuccess else { return .online }
        return syncStore.pending(limit: 1).isEmpty ? .offline : .failing
    }

    /// Asks the hub what cover art exists for this track and brings back the thumbnails.
    /// Returns an empty list rather than surfacing an error: the picker still has the
    /// local candidates to offer, and a failed archive lookup shouldn't block editing
    /// metadata. `nil` when there's no hub to ask at all, which hides the sections.
    private func hubArtworkLoader(
        for song: Song
    ) -> (() async -> [HubArtworkCandidate])? {
        guard let contentHash = song.contentHash else { return nil }
        return {
            guard let remote = await remoteSyncContext else { return [] }
            let candidates: [RemoteArtworkCandidate]
            do {
                candidates = try await remote.client.artworkCandidates(
                    contentHash: contentHash,
                    credential: remote.credential
                )
            } catch {
                Self.logger.warning(
                    "hub artwork lookup failed: \(String(describing: error), privacy: .public)"
                )
                return []
            }
            return await withTaskGroup(
                of: (Int, HubArtworkCandidate?).self
            ) { group in
                for (index, candidate) in candidates.enumerated() {
                    group.addTask {
                        guard let hash = candidate.thumbnail.split(separator: "/").last,
                              let data = try? await remote.client.downloadBlob(
                                  hash: String(hash),
                                  from: 0,
                                  credential: remote.credential
                              ),
                              !data.isEmpty else {
                            return (index, nil)
                        }
                        return (
                            index,
                            HubArtworkCandidate(
                                thumbnail: data,
                                fullImageURL: candidate.fullImageURL,
                                origin: candidate.origin,
                                album: candidate.album
                            )
                        )
                    }
                }
                // Reassembled in the hub's order, which puts this album's pressings
                // ahead of the artist's other records.
                var loaded: [(Int, HubArtworkCandidate)] = []
                for await (index, candidate) in group {
                    if let candidate {
                        loaded.append((index, candidate))
                    }
                }
                return loaded.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
    }

    private func resolveHubArtwork(
        _ candidate: HubArtworkCandidate
    ) async -> Data? {
        guard let remote = await remoteSyncContext else { return nil }
        guard let resolved = try? await remote.client.resolveArtwork(
            imageURL: candidate.fullImageURL,
            credential: remote.credential
        ) else { return nil }
        guard let hash = resolved.blob.split(separator: "/").last else { return nil }
        return try? await remote.client.downloadBlob(
            hash: String(hash),
            from: 0,
            credential: remote.credential
        )
    }

    private func resolveRemoteArtworkBlob(hash: String) async -> Data? {
        guard let remote = await remoteSyncContext else { return nil }
        return try? await remote.client.downloadBlob(
            hash: hash,
            from: 0,
            credential: remote.credential
        )
    }

    private func downloadCatalogArtwork(
        hashes: [String],
        client: AroSyncClient,
        credential: HubDeviceCredential?
    ) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            for hash in hashes {
                group.addTask {
                    let data = try? await client.downloadBlob(
                        hash: hash,
                        from: 0,
                        credential: credential
                    )
                    return (hash, data)
                }
            }
            var downloaded: [String: Data] = [:]
            for await (hash, data) in group {
                if let data, !data.isEmpty {
                    downloaded[hash] = data
                    syncStore.saveServerSnapshot(
                        data,
                        key: "artwork.\(hash)"
                    )
                }
            }
            return downloaded
        }
    }

    private func cachedCatalogArtwork(
        for tracks: [CatalogTrack]
    ) -> [String: Data] {
        var artwork: [String: Data] = [:]
        for hash in Set(tracks.compactMap(\.artworkHash)) {
            if let data = syncStore.cachedServerSnapshot(hashKey(hash), as: Data.self) {
                artwork[hash] = data
            }
        }
        return artwork
    }

    private func refreshServerStats(
        client: AroSyncClient,
        credential: HubDeviceCredential?
    ) async {
        guard let dashboard = try? await client.libraryStats(
            credential: credential
        ) else { return }
        cachedStatsDashboard = dashboard
        ScreenDataCache.saveStats(
            dashboard,
            for: profileRegistry.activeProfileID,
            store: syncStore
        )
    }

    private func hashKey(_ hash: String) -> String {
        "artwork.\(hash)"
    }

    private var addSyncIsDisabled: Bool {
        profileRegistry.activeProfile?.kind == .remote && !canContributeToActiveRemote
    }

    private var libraryDeviceID: UUID {
        UserDefaults.standard.string(forKey: "library.deviceID")
            .flatMap(UUID.init(uuidString:))
            ?? UUID()
    }

    private var activeServerConnection: LibraryServerConnection? {
        guard let profile = profileRegistry.activeProfile else { return nil }
        return LibraryServerConnection.resolve(
            profile: profile,
            operations: syncStore,
            deviceID: libraryDeviceID,
            localAdminToken: syncPreferences.localAdminToken
        )
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

        importStatus = "Importing music…"
        Task {
            do {
                guard let connection = activeServerConnection else {
                    throw AroSyncClientError.invalidResponse
                }
                if connection.isLocallyHosted {
                    let imported = try await connection.client.addAdminFolder(
                        path: url.path
                    )
                    importStatus = "Imported \(imported.songCount) files"
                } else {
                    guard let credential = connection.credential else {
                        throw HubCredentialError.missingRecord
                    }
                    let files = await Task.detached(priority: .utility) {
                        Self.importableFiles(in: url)
                    }.value
                    guard !files.isEmpty else {
                        throw AroSyncClientError.httpError(
                            status: 400,
                            message: "The selected folder contains no supported audio files."
                        )
                    }
                    let session = try await connection.client.createImport(
                        sourceName: url.lastPathComponent,
                        credential: credential
                    )
                    for (index, file) in files.enumerated() {
                        importStatus = "Uploading \(index + 1) of \(files.count)…"
                        let relative = String(
                            file.path.dropFirst(url.path.count)
                        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        try await connection.client.uploadImportFile(
                            importID: session.importID,
                            fileID: UUID(),
                            fileURL: file,
                            relativePath: relative,
                            credential: credential
                        )
                    }
                    var job = try await connection.client.commitImport(
                        importID: session.importID,
                        credential: credential
                    )
                    while [.pending, .running].contains(job.state) {
                        try await Task.sleep(for: .milliseconds(500))
                        job = try await connection.client.jobStatus(
                            jobID: job.jobID,
                            credential: credential
                        )
                    }
                    guard job.state == .completed else {
                        throw AroSyncClientError.httpError(
                            status: 500,
                            message: job.error ?? "The server could not ingest this folder."
                        )
                    }
                    _ = try await connection.client.exchange(
                        SyncExchangeRequest(
                            afterSequence: UInt64.max,
                            limit: 1,
                            operations: [],
                            deviceReport: DeviceSyncReport(
                                offlineTrackCount: UInt64(
                                    mediaCache.downloadedFileCount
                                ),
                                sources: [
                                    SourceHealthReport(
                                        sourceID: session.sourceID,
                                        name: url.lastPathComponent,
                                        mode: "managed",
                                        available: true,
                                        songCount: UInt64(files.count)
                                    )
                                ]
                            )
                        ),
                        credential: credential
                    )
                    importStatus = "Imported \(files.count) files"
                }
                if let profile = profileRegistry.activeProfile {
                    await synchronizeServerLibrary(profile)
                }
                try? await Task.sleep(for: .seconds(3))
                importStatus = nil
            } catch {
                importStatus = nil
                importError = error.localizedDescription
            }
        }
    }

    nonisolated private static func importableFiles(in root: URL) -> [URL] {
        let extensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "flac", "m4a", "mp3",
            "mp4", "oga", "ogg", "opus", "wav", "wave", "wv"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            guard extensions.contains(url.pathExtension.lowercased()),
                  values?.isRegularFile == true else { return nil }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

        Task {
            do {
                guard let connection = activeServerConnection,
                      connection.isLocallyHosted else {
                    throw AroSyncClientError.invalidResponse
                }
                _ = try await connection.client.relocateAdminFolder(
                    sourceID: id,
                    path: url.path
                )
                if let profile = profileRegistry.activeProfile {
                    await synchronizeServerLibrary(profile)
                }
            } catch {
                importError = error.localizedDescription
            }
        }
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
        Task {
            do {
                guard let connection = activeServerConnection,
                      connection.isLocallyHosted else {
                    throw AroSyncClientError.invalidResponse
                }
                try await connection.client.removeAdminFolder(sourceID: id)
                playback.reconcileAvailableSongs(
                    store.songsExcludingFolder(id: id)
                )
                if let profile = profileRegistry.activeProfile {
                    await synchronizeServerLibrary(profile)
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Location-neutral server transport for triggering identification.
    private var identificationSyncBridge: IdentificationSyncBridge {
        IdentificationSyncBridge(
            profile: profileRegistry.activeProfile,
            syncStore: syncStore,
            libraryDeviceID: libraryDeviceID,
            localAdminToken: syncPreferences.localAdminToken
        )
    }

    /// Same local-or-remote transport split as `identificationSyncBridge`, for the Home
    /// screen's server-generated playlists.
    private var homePlaylistsBridge: HomePlaylistsBridge {
        HomePlaylistsBridge(
            profile: profileRegistry.activeProfile,
            syncStore: syncStore,
            libraryDeviceID: libraryDeviceID,
            localAdminToken: syncPreferences.localAdminToken
        )
    }

    /// "Sync Track Data": right-click action that (re-)enqueues one track for
    /// background AcoustID/MusicBrainz identification. Addressed by content hash (and,
    /// for a self-hosted server, path) — not `song.libraryID`, which is local to this
    /// app's own catalog and aro-server has never heard of it.
    private func syncTrackData(_ song: Song) async {
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
