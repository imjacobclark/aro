import AroCommon
import SwiftUI

struct ArtistsView: View {
    let songs: [Song]
    let playback: PlaybackController
    let syncTrackData: (Song) async -> Void
    var loadRadio: ((String) async -> ServerGeneratedPlaylist?)?

    @State private var selectedArtistID: LibraryArtist.ID?
    @State private var searchText = ""
    @State private var pendingScrollTarget: LibraryArtist.ID?
    @FocusState private var isBrowserFocused: Bool

    private var artists: [LibraryArtist] {
        ArtistLibrary.artists(from: songs)
    }

    /// The playing song's artist, identified by running it through the same
    /// grouping that built `artists` — an artist's id is derived purely from
    /// its own name, so one song is enough to recover the id its artist would
    /// have in the full list, without re-deriving the normalisation here.
    private var nowPlayingArtistID: LibraryArtist.ID? {
        guard let song = playback.currentSong else { return nil }
        return ArtistLibrary.artists(from: [song]).first?.id
    }

    private var selectedArtist: LibraryArtist? {
        artists.first(where: { $0.id == selectedArtistID }) ?? artists.first
    }

    private var filteredArtists: [LibraryArtist] {
        artists.filter { FuzzySearch.matches(searchText, in: $0.name) }
    }

    /// Represents the collection being viewed rather than whatever is playing:
    /// on an artist or album page the useful question is "what else sounds like
    /// this record", and a seed that drifted with playback would make the shelf
    /// contradict its own heading.
    private func collectionSeed(_ visible: [Song]) -> Song? {
        visible.first { $0.contentHash != nil }
    }

    var body: some View {
        HStack(spacing: 0) {
            artistList

            Rectangle()
                .fill(AroTheme.hairline)
                .frame(width: 1)

            artistDetail
        }
        .task {
            focusNowPlayingArtist()
            // The row is only asked for once the lazy list has had a layout
            // pass to create it in; scrolling in the same turn as the
            // selection lands is a no-op.
            await Task.yield()
            pendingScrollTarget = selectedArtistID
        }
        .onChange(of: artists.map(\.id)) {
            selectFirstArtistIfNeeded()
        }
        .onChange(of: filteredArtists.map(\.id)) {
            selectFirstFilteredArtistIfNeeded()
        }
    }

    private var artistList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Artists")
                .font(AroFont.fixed(23, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 24)

            LibrarySearchField(
                prompt: "Search Artists",
                text: $searchText
            )

            ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredArtists) { artist in
                                Button {
                                    selectedArtistID = artist.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(artist.name)
                                            .font(AroFont.fixed(14, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(
                                            "\(artist.albums.count) albums · "
                                                + "\(artist.songs.count) songs"
                                        )
                                        .font(AroFont.fixed(12))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedArtistID == artist.id
                                            ? AroTheme.selectedTint
                                            : Color.clear,
                                        in: RoundedRectangle(
                                            cornerRadius: 9,
                                            style: .continuous
                                        )
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(
                                    selectedArtistID == artist.id
                                        ? .isSelected
                                        : []
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                }
                .overlay {
                    if filteredArtists.isEmpty {
                        ContentUnavailableView(
                            "No Matching Artists",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different artist name.")
                        )
                    }
                }
                .onChange(of: pendingScrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .center)
                    pendingScrollTarget = nil
                }
            }
        }
        .padding(.bottom, 12)
        .background(AroTheme.browserSurface)
        .frame(minWidth: 240, idealWidth: 272, maxWidth: 288)
        .focusable()
        .focusEffectDisabled()
        .focused($isBrowserFocused)
        .onMoveCommand(perform: moveBrowserSelection)
    }

    @ViewBuilder
    private var artistDetail: some View {
        if let artist = selectedArtist {
            VStack(spacing: 0) {
                header(title: artist.name, subtitle: artist.summary)

                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(artist.albums) { album in
                            LibraryAlbumSection(
                                name: album.name,
                                artistName: nil,
                                artworkData: album.artworkData,
                                songs: album.songs,
                                playback: playback,
                                syncTrackData: syncTrackData
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)

                    if let loadRadio {
                        MoreLikeThisSection(
                            seed: collectionSeed(artist.albums.flatMap(\.songs)),
                            seedLabel: artist.name,
                            allSongs: songs,
                            loadRadio: loadRadio,
                            playback: playback
                        )
                        .padding(.horizontal, 8)
                    }
                }
            }
            .background(AroTheme.contentSurface)
        } else {
            ContentUnavailableView(
                "No Artists Found",
                systemImage: "music.mic",
                description: Text(
                    "Add a music folder to browse artists and albums."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AroTheme.contentSurface)
        }
    }

    private func header(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AroFont.fixed(34, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)

                Text(subtitle)
                    .font(AroFont.fixed(14))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    /// Opens the browser on the artist you're currently listening to rather
    /// than the top of an alphabetical list: arriving here mid-song, that's
    /// almost always the one you came to look at. Falls back to the first
    /// artist when nothing is playing, or when the playing song's artist isn't
    /// part of this library.
    private func focusNowPlayingArtist() {
        if let nowPlayingArtistID,
           artists.contains(where: { $0.id == nowPlayingArtistID }) {
            selectedArtistID = nowPlayingArtistID
        }
        selectFirstArtistIfNeeded()
    }

    private func selectFirstArtistIfNeeded() {
        guard !artists.isEmpty else {
            selectedArtistID = nil
            return
        }
        if !artists.contains(where: { $0.id == selectedArtistID }) {
            selectedArtistID = artists.first?.id
        }
    }

    private func selectFirstFilteredArtistIfNeeded() {
        guard !filteredArtists.isEmpty else { return }
        if !filteredArtists.contains(where: { $0.id == selectedArtistID }) {
            selectedArtistID = filteredArtists.first?.id
        }
    }

    private func moveBrowserSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down,
              !filteredArtists.isEmpty else {
            return
        }
        let current = filteredArtists.firstIndex {
            $0.id == selectedArtistID
        } ?? 0
        let offset = direction == .down ? 1 : -1
        let next = min(
            max(current + offset, filteredArtists.startIndex),
            filteredArtists.index(before: filteredArtists.endIndex)
        )
        selectedArtistID = filteredArtists[next].id
    }
}
