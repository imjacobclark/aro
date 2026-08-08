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
    let editMetadata: (Song) -> Void
    /// Supplied only where a hub is reachable; when absent the "More Like This"
    /// shelf below simply doesn't render.
    var loadRadio: ((String) async -> ServerGeneratedPlaylist?)?
    /// Full catalog for resolving the hub's content hashes — the visible `songs`
    /// are usually a subset (one playlist, one folder).
    var allSongs: [Song] = []
    /// Supplied where the library is writable, so a row can be hearted without first
    /// having to play it. Absent leaves the action off the menu entirely.
    var setFavourite: ((Song, Bool) async throws -> Void)?

    @State private var songPendingRemoval: Song?
    @State private var removalError: String?

    /// `nil` where no hub is reachable, which is what keeps the menu item off the row
    /// rather than offering an action that could only fail.
    private var startRadioAction: (@MainActor (Song) -> Void)? {
        guard let loadRadio else { return nil }
        return { song in
            Task { await startRadio(from: song, using: loadRadio) }
        }
    }

    private var toggleFavouriteAction: (@MainActor (Song) -> Void)? {
        guard let setFavourite else { return nil }
        return { song in
            Task { try? await setFavourite(song, !song.isFavourite) }
        }
    }

    /// Plays the hub's seed-track station for a row.
    ///
    /// Radio used to be reachable only from Home, which made it a browsing feature rather
    /// than what it actually is: a property of any track you happen to be looking at.
    /// Silence on failure is deliberate and matches `MoreLikeThisSection` — an unanalysed
    /// seed or an unreachable hub is a station that does not exist yet, not an error the
    /// listener can act on.
    private func startRadio(
        from song: Song,
        using load: (String) async -> ServerGeneratedPlaylist?
    ) async {
        guard let contentHash = song.contentHash,
              let station = await load(contentHash) else { return }
        let queue = SongLibrary.resolving(station.contentHashes, in: allSongs)
        guard let first = queue.first else { return }
        playback.play(song: first, queue: queue)
    }

    /// Prefer whatever is playing — the shelf then tracks what you're actually
    /// listening to — falling back to the top of the list so it's still populated
    /// before playback starts.
    private var radioSeed: Song? {
        if let current = playback.currentSong,
           current.contentHash != nil {
            return current
        }
        return songs.first { $0.contentHash != nil }
    }

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
                    onEditMetadata: { song in editMetadata(song) },
                    onRequestRemoval: { song in
                        songPendingRemoval = song
                    },
                    onStartRadio: startRadioAction,
                    onToggleFavourite: toggleFavouriteAction,
                    onPlayNext: { song in playback.playNext(song) },
                    onAddToQueue: { song in playback.addToQueue(song) },
                    // The heading names the collection on screen, so it changes
                    // exactly when you navigate between one and another — which
                    // is when the table should re-centre on the playing track,
                    // and not while a scan is quietly appending rows to the one
                    // you're already reading.
                    focusToken: title
                )
                if let loadRadio {
                    MoreLikeThisSection(
                        seed: radioSeed,
                        isCollapsible: true,
                        allSongs: allSongs,
                        loadRadio: loadRadio,
                        playback: playback
                    )
                }
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
        let cachedHashes = mediaCache.cachedContentHashes
        return Set(songs.lazy.filter { song in
            guard !song.url.isFileURL else {
                return true
            }
            guard let hash = song.fileFingerprint?.contentHash else {
                return false
            }
            return cachedHashes.contains(hash)
        }.map(\.id))
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
