import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    @Bindable var playback: PlaybackController

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $store.selection) {
                Section("Library") {
                    Label("Songs", systemImage: "music.note.list")
                        .tag(Destination.songs)
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

            if store.selection == .stats {
                StatsView(playback: playback)
            } else if store.selection == .libraryHealth {
                LibraryHealthView()
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 230)

                    PlayerBar(playback: playback)
                        .frame(
                            width: min(
                                max((geometry.size.width - 230) * 0.5, 500),
                                650
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .frame(height: 84)
        }
        .overlay(alignment: .bottomLeading) {
            ChillVisualizer(
                levels: playback.visualizerLevels,
                isActive: playback.isPlaying
            )
            .frame(width: 230, height: 230)
            .allowsHitTesting(false)
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

private struct ChillVisualizer: View {
    let levels: [Double]
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 24,
                paused: !isActive || reduceMotion
            )
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let rotation = reduceMotion ? 0 : time * 0.16

            Canvas { context, size in
                let side = min(size.width, size.height)
                let center = CGPoint(
                    x: size.width / 2,
                    y: size.height / 2
                )
                let quietLevel = isActive ? 0.04 : 0

                for radius in [side * 0.25, side * 0.38] {
                    let ring = Path(
                        ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    )
                    context.stroke(
                        ring,
                        with: .color(.white.opacity(0.07)),
                        lineWidth: 0.7
                    )
                }

                var waveform = Path()
                let pointCount = 48

                for pointIndex in 0..<pointCount {
                    let angle = (Double(pointIndex) / Double(pointCount))
                        * .pi * 2
                        + rotation
                        - (.pi / 2)
                    let level = interpolatedLevel(
                        at: pointIndex,
                        pointCount: pointCount
                    )
                    let radialLevel = peakLevel * 0.72 + level * 0.28
                    let radius = side * 0.19
                        + max(radialLevel, quietLevel) * side * 0.23
                    let point = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )

                    if pointIndex == 0 {
                        waveform.move(to: point)
                    } else {
                        waveform.addLine(to: point)
                    }

                    let rayStart = CGPoint(
                        x: center.x + cos(angle) * side * 0.13,
                        y: center.y + sin(angle) * side * 0.13
                    )
                    var ray = Path()
                    ray.move(to: rayStart)
                    ray.addLine(to: point)
                    context.stroke(
                        ray,
                        with: .color(
                            SonoraTheme.orbitColor(
                                at: Double(pointIndex)
                                    / Double(pointCount - 1)
                            )
                            .opacity(0.16 + radialLevel * 0.38)
                        ),
                        lineWidth: 0.65
                    )
                }
                waveform.closeSubpath()

                context.drawLayer { layer in
                    layer.addFilter(
                        .shadow(
                            color: SonoraTheme.coral.opacity(
                                isActive ? 0.38 : 0.1
                            ),
                            radius: 7
                        )
                    )
                    layer.fill(
                        waveform,
                        with: .linearGradient(
                            Gradient(
                                colors: [
                                    SonoraTheme.violet.opacity(0.58),
                                    SonoraTheme.coral.opacity(0.52),
                                    SonoraTheme.amber.opacity(0.55)
                                ]
                            ),
                            startPoint: CGPoint(
                                x: side * 0.16,
                                y: side * 0.16
                            ),
                            endPoint: CGPoint(
                                x: side * 0.84,
                                y: side * 0.84
                            )
                        )
                    )
                    layer.stroke(
                        waveform,
                        with: .color(
                            SonoraTheme.coral.opacity(isActive ? 0.88 : 0.3)
                        ),
                        lineWidth: 1.1
                    )
                }

                let coreSize = side * (0.09 + averageLevel * 0.07)
                let core = Path(
                    ellipseIn: CGRect(
                        x: center.x - coreSize / 2,
                        y: center.y - coreSize / 2,
                        width: coreSize,
                        height: coreSize
                    )
                )
                context.fill(
                    core,
                    with: .radialGradient(
                        Gradient(
                            colors: [
                                .white,
                                SonoraTheme.amber,
                                SonoraTheme.violet
                            ]
                        ),
                        center: center,
                        startRadius: 0,
                        endRadius: coreSize
                    )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .glassEffect(
                .regular,
                in: Rectangle()
            )
            .overlay {
                Rectangle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.18),
                                SonoraTheme.coral.opacity(0.14),
                                SonoraTheme.violet.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            }
            .opacity(isActive ? 1 : 0.52)
            .animation(
                reduceMotion
                    ? nil
                    : .smooth(duration: 0.14, extraBounce: 0.04),
                value: levels
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.25),
                value: isActive
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback visualizer")
        .accessibilityValue(isActive ? "Playing" : "Idle")
    }

    private var averageLevel: Double {
        guard !levels.isEmpty else {
            return 0
        }
        return levels.reduce(0, +) / Double(levels.count)
    }

    private var peakLevel: Double {
        levels.max() ?? 0
    }

    private func interpolatedLevel(
        at pointIndex: Int,
        pointCount: Int
    ) -> Double {
        guard !levels.isEmpty else {
            return 0
        }

        // Repeat the same contour in four quadrants. Opposing sides now move
        // together, while the local waveform still gives the disc texture.
        let quadrantPointCount = max(pointCount / 4, 1)
        let pointInQuadrant = pointIndex % quadrantPointCount
        let position = Double(pointInQuadrant) * Double(levels.count)
            / Double(quadrantPointCount)
        let lowerIndex = Int(position) % levels.count
        let upperIndex = (lowerIndex + 1) % levels.count
        let fraction = position - floor(position)
        return levels[lowerIndex] * (1 - fraction)
            + levels[upperIndex] * fraction
    }
}

private struct FolderRow: View {
    let folder: WatchedFolder
    let scanState: FolderScanState

    var body: some View {
        HStack {
            Label(folder.displayName, systemImage: "folder")
                .lineLimit(1)

            Spacer()

            switch scanState {
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Scanning")
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Folder warning")
            case .idle:
                EmptyView()
            }
        }
    }
}

private struct SongTableView: View {
    let title: String
    let songs: [Song]
    let scanState: FolderScanState
    let hasWatchedFolders: Bool
    @Bindable var playback: PlaybackController

    @State private var selectedSongID: Song.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(SonoraFont.largeTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)

                    Text(LibrarySummary(songs: songs).formatted)
                        .font(SonoraFont.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 12)

                AppSettingsButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)

            if case .warning(let message) = scanState, !songs.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(SonoraFont.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }

            ZStack {
                Table(songs, selection: $selectedSongID) {
                    TableColumn("Title") { song in
                        HStack(spacing: 6) {
                            if playback.currentSong?.id == song.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Currently playing")
                            }
                            Text(song.title)
                        }
                    }
                    TableColumn("Artist", value: \.artist)
                    TableColumn("Duration") { song in
                        Text(song.formattedDuration)
                            .monospacedDigit()
                    }
                    .width(min: 72, ideal: 88, max: 110)
                }
                .contextMenu(forSelectionType: Song.ID.self) { selectedIDs in
                    Button("Play") {
                        playFirstSong(in: selectedIDs)
                    }
                    .disabled(selectedIDs.isEmpty)
                } primaryAction: { selectedIDs in
                    playFirstSong(in: selectedIDs)
                }

                if songs.isEmpty {
                    emptyState
                }
            }
        }
        .onChange(of: songs.map(\.id)) { _, songIDs in
            guard let selectedSongID,
                  !songIDs.contains(selectedSongID) else {
                return
            }
            self.selectedSongID = nil
        }
    }

    private func playFirstSong(in selectedIDs: Set<Song.ID>) {
        guard let selectedID = selectedIDs.first,
              let song = songs.first(where: { $0.id == selectedID }) else {
            return
        }

        selectedSongID = selectedID
        playback.play(song: song, queue: songs)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch scanState {
        case .scanning:
            ContentUnavailableView {
                Label("Scanning for Audio", systemImage: "waveform")
            } description: {
                ProgressView()
                    .controlSize(.small)
            }
        case .warning(let message):
            ContentUnavailableView(
                "Unable to Load Audio",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .idle where !hasWatchedFolders:
            ContentUnavailableView(
                "No Watched Folders",
                systemImage: "folder.badge.plus",
                description: Text("Use the + button beside Watched Folders to add your music.")
            )
        case .idle:
            ContentUnavailableView(
                "No Audio Found",
                systemImage: "music.note",
                description: Text("This selection contains no playable audio files.")
            )
        }
    }
}

@MainActor
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            store: LibraryStore(
                defaults: UserDefaults(suiteName: "SonoraPreview")!
            ),
            playback: PlaybackController()
        )
        .frame(width: 900, height: 600)
    }
}
