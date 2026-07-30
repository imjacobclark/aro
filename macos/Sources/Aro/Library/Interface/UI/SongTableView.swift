import SwiftUI
import AroCommon

struct SongTableView: View {
    let title: String
    let songs: [Song]
    let scanState: FolderScanState
    let hasWatchedFolders: Bool
    let playback: PlaybackController
    let mediaCache: MediaCacheController
    let usesStreamOnlyIcon: Bool
    let storesLibraryCopy: Bool
    let removeSong: (Song) async throws -> Void
    let syncTrackData: (Song) async -> Void

    @State private var songPendingRemoval: Song?
    @State private var removalError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AroFont.largeTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)

                    Text(LibrarySummary(songs: songs).formatted)
                        .font(AroFont.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 12)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)

            if case .warning(let message) = scanState, !songs.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(AroFont.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }

            if songs.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AppKitSongTable(
                    songs: songs,
                    currentSongID: playback.currentSong?.id,
                    downloadedSongIDs: downloadedSongIDs,
                    usesStreamOnlyIcon: usesStreamOnlyIcon,
                    presentation: .library,
                    onPlay: { song in
                        playback.play(song: song, queue: songs)
                    },
                    onSyncTrackData: { song in
                        await syncTrackData(song)
                    },
                    onRequestRemoval: { song in
                        songPendingRemoval = song
                    }
                )
            }
        }
        .confirmationDialog(
            "Remove \(songPendingRemoval?.title ?? "this song") from Aro?",
            isPresented: Binding(
                get: { songPendingRemoval != nil },
                set: { if !$0 { songPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Aro", role: .destructive) {
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
                    ? "Aro never deletes the original file. Its stored copy remains recoverable for 30 days."
                    : "Aro removes the song from its library but never deletes the linked file."
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

    private var downloadedSongIDs: Set<Song.ID> {
        Set(songs.lazy.filter(isDownloaded).map(\.id))
    }

    private func isDownloaded(_ song: Song) -> Bool {
        guard !song.url.isFileURL else {
            return true
        }
        guard let hash = song.fileFingerprint?.contentHash else {
            return false
        }
        return mediaCache.isCached(hash: hash)
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
