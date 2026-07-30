import AroCommon
import SwiftUI

/// Home screen: a "Made for You" grid of the hub's auto-generated playlists plus a
/// "Recently Played" row, in the same page shell as `StatsView` (title, `ScrollView`,
/// periodic refresh). The server is the canonical generator — it owns the listening
/// analytics, favourites, and MusicBrainz mood tags playlists are derived from (see
/// `aro-server`'s `playlists` module); this view only maps the returned content hashes
/// onto the local catalog and renders. Owns its own local grid/detail navigation state
/// rather than pushing onto a `NavigationStack`, matching the app's existing flat,
/// non-stack content-swapping model.
struct HomeView: View {
    /// A closure rather than a plain `[Song]` so the periodic refresh loop below always
    /// reads the *current* library — a captured `[Song]` value would go stale for the
    /// lifetime of the `.task`, since SwiftUI doesn't restart an already-running task
    /// just because a struct's stored property changed on a later render.
    let allSongs: () -> [Song]
    let playback: PlaybackController
    let mediaCache: MediaCacheController
    let usesStreamOnlyIcon: Bool
    let storesLibraryCopy: Bool
    /// Fetches the hub's current playlists via `HomePlaylistsBridge` — empty when no
    /// server is reachable yet; the poll below just tries again.
    let loadPlaylists: () async -> [ServerGeneratedPlaylist]
    let removeSong: (Song) async throws -> Void
    let syncTrackData: (Song) async -> Void

    @State private var playlists: [ServerGeneratedPlaylist] = []
    @State private var selectedPlaylist: ServerGeneratedPlaylist?

    var body: some View {
        Group {
            if let selectedPlaylist {
                PlaylistDetailView(
                    playlist: selectedPlaylist,
                    songs: songs(for: selectedPlaylist),
                    playback: playback,
                    mediaCache: mediaCache,
                    usesStreamOnlyIcon: usesStreamOnlyIcon,
                    storesLibraryCopy: storesLibraryCopy,
                    removeSong: removeSong,
                    syncTrackData: syncTrackData,
                    onBack: { self.selectedPlaylist = nil }
                )
            } else {
                homeGrid
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: playback.currentSong?.id) {
            Task { await refresh() }
        }
    }

    private var homeGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home")
                        .font(AroFont.largeTitle)
                    Text("Playlists made from your listening.")
                        .font(AroFont.subheadline)
                        .foregroundStyle(.secondary)
                }

                if visiblePlaylists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists Yet",
                        systemImage: "sparkles",
                        description: Text(
                            "Keep listening and favouriting songs — Aro will start making playlists for you here."
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 240)
                } else {
                    madeForYouSection
                    if let recentlyPlayed = visiblePlaylists.first(
                        where: { $0.id == "recently-played" }
                    ) {
                        recentlyPlayedSection(recentlyPlayed)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
    }

    /// Playlists that still have at least one song present in this device's catalog —
    /// a hub can know about tracks a client hasn't synced yet, and an all-missing
    /// playlist would render as an empty, unplayable card.
    private var visiblePlaylists: [ServerGeneratedPlaylist] {
        playlists.filter { !songs(for: $0).isEmpty }
    }

    private var madeForYouSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Made for You")
                .font(AroFont.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                spacing: 16
            ) {
                ForEach(visiblePlaylists) { playlist in
                    Button {
                        selectedPlaylist = playlist
                    } label: {
                        PlaylistCard(playlist: playlist, songs: songs(for: playlist))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { play(playlist) }
                    }
                }
            }
        }
    }

    private func recentlyPlayedSection(
        _ playlist: ServerGeneratedPlaylist
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently Played")
                .font(AroFont.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(songs(for: playlist).prefix(12)) { song in
                        Button {
                            playback.play(
                                song: song,
                                queue: songs(for: playlist)
                            )
                        } label: {
                            recentlyPlayedTile(song)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func recentlyPlayedTile(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(data: song.artworkData, maxDimension: 96)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(AroFont.textStyle(.caption, weight: .semibold))
                    .lineLimit(1)
                Text(song.artist)
                    .font(AroFont.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 96, alignment: .leading)
    }

    private func songs(for playlist: ServerGeneratedPlaylist) -> [Song] {
        let songsByHash = Dictionary(
            allSongs().compactMap { song in
                song.contentHash.map { ($0, song) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return playlist.contentHashes.compactMap { songsByHash[$0] }
    }

    private func play(_ playlist: ServerGeneratedPlaylist) {
        let songs = songs(for: playlist)
        guard let first = songs.first else { return }
        playback.play(song: first, queue: songs)
    }

    private func refresh() async {
        let fetched = await loadPlaylists()
        // A transiently unreachable server yields [] — keep showing the last known
        // playlists rather than blanking Home until the next successful poll.
        guard !fetched.isEmpty else { return }
        playlists = fetched
        if let selectedPlaylist {
            self.selectedPlaylist = fetched.first { $0.id == selectedPlaylist.id }
                ?? selectedPlaylist
        }
    }
}
