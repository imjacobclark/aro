import AppKit
import SonoraCommon
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    @Bindable var playback: PlaybackController
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: AudioDeviceManager
    let reviewLibraryHealth: ReviewLibraryHealth
    let loadStatsDashboard: LoadStatsDashboard

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
                            Text("Watched Folders")
                            Spacer()
                            Button(action: chooseFolder) {
                                Image(systemName: "plus")
                                    .accessibilityLabel("Add Watched Folder")
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
                } else {
                    SongTableView(
                        title: store.selectedTitle,
                        songs: store.visibleSongs,
                        scanState: store.selectedScanState,
                        hasWatchedFolders: !store.folders.isEmpty,
                        playback: playback
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
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Watch"
        panel.prompt = "Watch Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        store.addFolder(url)
    }

    private func removeFolder(id: UUID) {
        playback.reconcileAvailableSongs(
            store.songsExcludingFolder(id: id)
        )
        store.removeFolder(id: id)
    }
}
