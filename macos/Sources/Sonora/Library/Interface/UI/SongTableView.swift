import SwiftUI
import SonoraCommon

struct SongTableView: View {
    let title: String
    let songs: [Song]
    let scanState: FolderScanState
    let hasWatchedFolders: Bool
    @Bindable var playback: PlaybackController
    let storesLibraryCopy: Bool
    let removeSong: (Song) async throws -> Void

    @State private var selectedSongID: Song.ID?
    @State private var songPendingRemoval: Song?
    @State private var removalError: String?

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
                    Divider()
                    Button("Remove from Sonora…", role: .destructive) {
                        songPendingRemoval = songs.first {
                            selectedIDs.contains($0.id)
                        }
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
        .confirmationDialog(
            "Remove \(songPendingRemoval?.title ?? "this song") from Sonora?",
            isPresented: Binding(
                get: { songPendingRemoval != nil },
                set: { if !$0 { songPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Sonora", role: .destructive) {
                guard let song = songPendingRemoval else { return }
                Task {
                    do {
                        try await removeSong(song)
                    } catch {
                        removalError = error.localizedDescription
                    }
                    songPendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                storesLibraryCopy
                    ? "Sonora never deletes the original file. Its stored copy remains recoverable for 30 days."
                    : "Sonora removes the song from its library but never deletes the linked file."
            )
        }
        .alert(
            "Couldn’t Remove Song",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "Unknown error")
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
                "No Syncs",
                systemImage: "folder.badge.plus",
                description: Text("Use the + button beside Syncs to add your music.")
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
