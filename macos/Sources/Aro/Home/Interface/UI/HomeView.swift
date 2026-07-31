import AroCommon
import SwiftUI

/// Home screen: an editorial, curated stack of horizontal carousels built from the
/// hub's auto-generated playlists, in the same page shell as `StatsView` (title,
/// `ScrollView`, periodic refresh). The server is the canonical generator — it owns
/// the listening analytics, favourites, artist/year groupings, and MusicBrainz mood
/// tags playlists are derived from (see `aro-server`'s `playlists` module); this view
/// only maps the returned content hashes onto the local catalog, groups them by
/// `PlaylistKind` into four sections (Hero Mixes, Top Picks For You, Jump Back In,
/// Made For Your Library), and renders. Owns its own local grid/detail navigation
/// state rather than pushing onto a `NavigationStack`, matching the app's existing
/// flat, non-stack content-swapping model.
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
    /// Tier 3 "seed-track radio" (see `aro-server`'s `playlists::radio`) for a given
    /// song's content hash — `nil` if unreachable or the seed hasn't been analyzed.
    let loadRadio: (String) async -> ServerGeneratedPlaylist?
    let removeSong: (Song) async throws -> Void
    let syncTrackData: (Song) async -> Void
    /// Owned by `ContentView`, not this view: `HomeView` is torn down and rebuilt
    /// every time the sidebar selection leaves Home and comes back (see
    /// `ContentView`'s `if/else if` content switcher), which would otherwise reset
    /// a local `@State` back to empty and force a blank grid until the next
    /// successful poll. Binding to a value that outlives this view gives Home a
    /// stale-while-revalidate feel: the last known playlists render immediately,
    /// and `refresh()` below quietly replaces them once the poll completes.
    @Binding var playlists: [ServerGeneratedPlaylist]

    @State private var selectedPlaylist: ServerGeneratedPlaylist?

    /// The two `forYou`-kind recipes explicitly reserved for "Made For Your Library"
    /// (Favorites Mix, Deep Cuts) — excluded from the Hero row so they don't render
    /// twice.
    private static let madeForLibraryForYouIDs: Set<String> = ["recently-loved", "deep-cuts"]

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
                    loadRadio: loadRadio,
                    allSongs: allSongs(),
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
            VStack(alignment: .leading, spacing: 32) {
                header

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
                    if !heroPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Your Mixes")
                            HeroMixCarousel(
                                playlists: heroPlaylists,
                                onSelect: { selectedPlaylist = $0 },
                                onPlay: { play($0) },
                                onStartRadio: { playlist in
                                    Task {
                                        if let first = songs(for: playlist).first {
                                            await startRadio(from: first)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    section(
                        title: "Top Picks For You",
                        subtitle: "Because of what you've been playing",
                        playlists: topPicks
                    )
                    ForEach(qualifyingArtistMixes) { playlist in
                        artistSongRow(playlist)
                    }
                    section(
                        title: "Jump Back In",
                        subtitle: "Pick up where you left off",
                        playlists: jumpBackIn
                    )
                    section(
                        title: "Made For Your Library",
                        subtitle: "Intelligence built entirely from your own collection",
                        playlists: madeForLibrary
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home")
                .font(AroFont.largeTitle)
            Text(greeting)
                .font(AroFont.textStyle(.title2, weight: .semibold))
            Text("Your music, curated.")
                .font(AroFont.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// Playlists that still have at least one song present in this device's catalog —
    /// a hub can know about tracks a client hasn't synced yet, and an all-missing
    /// playlist would render as an empty, unplayable card.
    private var visiblePlaylists: [ServerGeneratedPlaylist] {
        playlists.filter { !songs(for: $0).isEmpty }
    }

    /// The curated "recipe" mixes — Heavy Rotation, Deep Cuts, Forgotten Favourites,
    /// Fresh Finds, Morning/Late Night, Workout/Wind Down, Daily Mixes, Radio — minus
    /// the two reserved for "Made For Your Library" below. Daily Mixes lead the row:
    /// they're the most personal of the bunch (k-means clusters over this listener's
    /// own analyzed tracks), so they get first billing ahead of the more generic
    /// recipes. `sorted` is stable, so everything else keeps the server's own order.
    private var heroPlaylists: [ServerGeneratedPlaylist] {
        visiblePlaylists
            .filter { $0.kind == .forYou && !Self.madeForLibraryForYouIDs.contains($0.id) }
            .sorted { $0.id.hasPrefix("daily-mix") && !$1.id.hasPrefix("daily-mix") }
    }

    /// A mixed row of mood- and year-flavoured picks, each carrying its own "reason"
    /// subtitle already. Deliberately excludes `.favouriteArtist` (a bare artist name
    /// isn't a useful card on its own) and `.artistMix` (which gets its own dedicated
    /// row per artist below, since "More From X" wants to show individual songs, not
    /// a single mosaic tile).
    private var topPicks: [ServerGeneratedPlaylist] {
        visiblePlaylists.filter { [.mood, .hitsByYear].contains($0.kind) }
    }

    /// "More From `<Artist>`" playlists worth their own row — only artists with more
    /// than one distinct album in the playlist actually benefit from a dedicated row;
    /// a single-album artist's tracks would all show the same cover anyway.
    private var qualifyingArtistMixes: [ServerGeneratedPlaylist] {
        visiblePlaylists.filter { playlist in
            guard playlist.kind == .artistMix else { return false }
            let albums = Set(songs(for: playlist).compactMap(\.album))
            return albums.count > 1
        }
    }

    /// Nostalgic, resume-flavoured picks.
    private var jumpBackIn: [ServerGeneratedPlaylist] {
        visiblePlaylists.filter { [.recentlyPlayedAlbum, .replayMonth].contains($0.kind) }
    }

    /// Library-intelligence mixes: Time Capsule, Lost Albums, Replay All Time, plus
    /// Favorites Mix ("recently-loved") and Deep Cuts pulled out of the `forYou` bucket.
    /// Also the catch-all for `.unknown`: a playlist kind this build predates still
    /// gets shown and stays playable here rather than being silently dropped, which
    /// is the whole point of decoding it leniently in the first place.
    private var madeForLibrary: [ServerGeneratedPlaylist] {
        visiblePlaylists.filter {
            [.timeCapsule, .lostAlbum, .replayAllTime, .unknown].contains($0.kind)
                || Self.madeForLibraryForYouIDs.contains($0.id)
        }
    }

    private func section(
        title: String,
        subtitle: String,
        playlists sectionPlaylists: [ServerGeneratedPlaylist]
    ) -> some View {
        Group {
            if !sectionPlaylists.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: title, subtitle: subtitle)
                    playlistRow(sectionPlaylists)
                }
            }
        }
    }

    private func playlistRow(_ sectionPlaylists: [ServerGeneratedPlaylist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(sectionPlaylists) { playlist in
                    PlayableCard(
                        onSelect: { selectedPlaylist = playlist },
                        onPlay: { play(playlist) }
                    ) {
                        card(for: playlist)
                    }
                    .contextMenu {
                        Button("Play") { play(playlist) }
                        if let firstSong = songs(for: playlist).first {
                            Button("Start Radio") {
                                Task { await startRadio(from: firstSong) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Picks the card style that matches what a playlist actually represents:
    /// artwork-forward for anything tied to a real artist/album/year, a gradient
    /// cover for taste/vibe groupings, and the bigger icon-forward mix style for
    /// everything else (the curated recipes, replay, time capsule). `.artistMix` and
    /// `.favouriteArtist` never actually reach this — they're routed to their own
    /// dedicated row (`qualifyingArtistMixes`) or hidden entirely — but stay listed so
    /// the switch remains exhaustive as new kinds get added.
    @ViewBuilder
    private func card(for playlist: ServerGeneratedPlaylist) -> some View {
        switch playlist.kind {
        case .recentlyPlayedAlbum, .artistMix, .favouriteArtist, .hitsByYear, .lostAlbum:
            AlbumCard(playlist: playlist, songs: songs(for: playlist))
        case .mood:
            PlaylistCard(playlist: playlist)
        case .forYou, .timeCapsule, .replayMonth, .replayAllTime, .recentlyPlayedTrack,
             .unknown:
            MixCard(playlist: playlist)
        }
    }

    /// "More From `<Artist>`"'s dedicated row — individual song tiles rather than a
    /// single mosaic card, since the point is picking a specific song, not opening a
    /// detail view. Tiles are diversified by album for display so the row doesn't show
    /// the same cover repeatedly; playback keeps the server's real ranked order.
    private func artistSongRow(_ playlist: ServerGeneratedPlaylist) -> some View {
        let rowSongs = songs(for: playlist)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: playlist.title, subtitle: playlist.subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(rowSongs.diverseByAlbum(count: 12)) { song in
                        Button {
                            playback.play(song: song, queue: rowSongs)
                        } label: {
                            songTile(song)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Start Radio") {
                                Task { await startRadio(from: song) }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func songTile(_ song: Song) -> some View {
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

    /// Fetches Tier 3 "seed-track radio" from `song` and starts playing it — a no-op
    /// (rather than an error) if the seed hasn't been analyzed yet or no server is
    /// reachable, since this is a context-menu convenience, not a critical action.
    private func startRadio(from song: Song) async {
        guard let contentHash = song.contentHash,
              let radioPlaylist = await loadRadio(contentHash) else { return }
        let queue = songs(for: radioPlaylist)
        guard let first = queue.first else { return }
        playback.play(song: first, queue: queue)
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
