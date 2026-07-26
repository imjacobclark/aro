import AppKit
import SonoraCommon
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    @Bindable var playback: PlaybackController
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: AudioDeviceManager
    @Bindable var profileRegistry: LibraryProfileRegistry
    @Bindable var hubService: SonoraHubService
    @Bindable var syncPreferences: SyncPreferences
    @Bindable var mediaCache: MediaCacheController
    let reviewLibraryHealth: ReviewLibraryHealth
    let loadStatsDashboard: LoadStatsDashboard
    let syncStore: SQLiteSyncOperationStore
    let libraryFiles: any LibraryFileManaging
    let removeSong: (Song) async throws -> Void
    let activateProfile: (LibraryProfile) -> Void
    let completeRemoteConnection: (
        SonoraHubInfo,
        URL,
        String,
        OfflineDownloadPolicy
    ) -> Void
    @State private var importStatus: String?
    @State private var importError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                List(selection: $store.selection) {
                    Section("Library") {
                        Label("Songs", systemImage: "music.note.list")
                            .tag(Destination.songs)
                        Label("Artists", systemImage: "music.mic")
                            .tag(Destination.artists)
                        Label("Albums", systemImage: "square.stack")
                            .tag(Destination.albums)
                        Label("Stats", systemImage: "chart.bar.xaxis")
                            .tag(Destination.stats)
                        Label("Library Health", systemImage: "checkmark.shield")
                            .tag(Destination.libraryHealth)
                        Label("Devices", systemImage: "macbook.and.iphone")
                            .tag(Destination.devices)
                    }

                    Section {
                        ForEach(store.folders) { folder in
                            FolderRow(
                                folder: folder,
                                scanState: store.scanStates[folder.id] ?? .idle
                            )
                            .tag(Destination.folder(folder.id))
                            .contextMenu {
                                Button("Remove Folder", role: .destructive) {
                                    removeFolder(id: folder.id)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Syncs")
                            Spacer()
                            Button(action: chooseFolder) {
                                Image(systemName: "plus")
                                    .accessibilityLabel("Add Sync")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 230)

                Divider()

                if store.selection == .artists {
                    ArtistsView(
                        songs: store.allSongs,
                        playback: playback
                    )
                } else if store.selection == .albums {
                    AlbumsView(
                        songs: store.allSongs,
                        playback: playback
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
                } else if store.selection == .devices {
                    DevicesView(
                        library: store,
                        registry: profileRegistry,
                        service: hubService,
                        preferences: syncPreferences,
                        mediaCache: mediaCache,
                        syncStore: syncStore,
                        libraryFiles: libraryFiles,
                        activateProfile: activateProfile,
                        completeRemoteConnection: completeRemoteConnection
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
                        storesLibraryCopy:
                            profileRegistry.activeProfile?.managedMusicPath != nil,
                        removeSong: removeSong
                    )
                }
                }
            // Reserve room at the bottom so scrollable content can clear the
            // floating player bar without the bar covering the last row.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 84)
            }
            // Applied after the inset so the visualizer sits flush against the
            // true bottom of the window rather than being pushed up by it.
            .overlay(alignment: .bottomLeading) {
                ChillVisualizer(
                    levels: playback.visualizerLevels,
                    isActive: playback.isPlaying
                )
                .frame(width: 230, height: 230)
                .allowsHitTesting(false)
            }

            // Last in the ZStack, so the bar floats above the visualizer.
            GeometryReader { geometry in
                PlayerBar(playback: playback, preferences: preferences, deviceManager: deviceManager)
                    .frame(
                        width: min(max(geometry.size.width * 0.65, 650), 845)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .frame(height: 84)
        }
        .task {
            store.start()
            playback.reconcileAvailableSongs(store.allSongs)
        }
        .onChange(of: store.allSongs.map(\.id)) {
            playback.reconcileAvailableSongs(store.allSongs)
        }
        .overlay(alignment: .top) {
            if let importStatus {
                Label(importStatus, systemImage: "square.and.arrow.down")
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

    private func removeFolder(id: UUID) {
        playback.reconcileAvailableSongs(
            store.songsExcludingFolder(id: id)
        )
        store.removeFolder(id: id)
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
                    + "into Sonora will remain in Sonora."
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
                "Sonora will stop checking this folder. Music already "
                    + "synced into Sonora will remain in Sonora."
            )
        }
    }
}
