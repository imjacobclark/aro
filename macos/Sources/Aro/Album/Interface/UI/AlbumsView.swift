import AroCommon
import SwiftUI

struct AlbumsView: View {
    let songs: [Song]
    let playback: PlaybackController
    let syncTrackData: (Song) async -> Void
    let syncAlbumData: ([Song]) async -> Void
    let editMetadata: (MetadataEditorContext) -> Void
    var loadRadio: ((String) async -> ServerGeneratedPlaylist?)?

    @State private var selectedAlbumID: LibraryAlbum.ID?
    @State private var searchText = ""
    @State private var pendingScrollTarget: LibraryAlbum.ID?
    @FocusState private var isBrowserFocused: Bool

    private var albums: [LibraryAlbum] {
        AlbumLibrary.albums(from: songs)
    }

    /// The playing song's album, identified by running it through the same
    /// grouping that built `albums` — an album's id is derived purely from its
    /// own artist and album names, so one song is enough to recover the id its
    /// album would have in the full list.
    private var nowPlayingAlbumID: LibraryAlbum.ID? {
        guard let song = playback.currentSong else { return nil }
        return AlbumLibrary.albums(from: [song]).first?.id
    }

    private var selectedAlbum: LibraryAlbum? {
        albums.first(where: { $0.id == selectedAlbumID }) ?? albums.first
    }

    private var filteredAlbums: [LibraryAlbum] {
        albums.filter {
            FuzzySearch.matches(
                searchText,
                in: $0.name + " " + $0.artistName
            )
        }
    }

    /// Represents the album being viewed rather than whatever is playing — see
    /// `ArtistsView.collectionSeed`.
    private func collectionSeed(_ visible: [Song]) -> Song? {
        visible.first { $0.contentHash != nil }
    }

    var body: some View {
        HStack(spacing: 0) {
            albumList

            Rectangle()
                .fill(AroTheme.hairline)
                .frame(width: 1)

            albumDetail
        }
        .task {
            focusNowPlayingAlbum()
            // See `ArtistsView`: the lazy list needs a layout pass before it
            // has a row to scroll to.
            await Task.yield()
            pendingScrollTarget = selectedAlbumID
        }
        .onChange(of: albums.map(\.id)) {
            selectFirstAlbumIfNeeded()
        }
        .onChange(of: filteredAlbums.map(\.id)) {
            selectFirstFilteredAlbumIfNeeded()
        }
    }

    private var albumList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Albums")
                .font(AroFont.fixed(23, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 24)

            LibrarySearchField(
                prompt: "Search Albums",
                text: $searchText
            )

            ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredAlbums) { album in
                                Button {
                                    selectedAlbumID = album.id
                                } label: {
                                    HStack(spacing: 10) {
                                        AlbumArtworkView(data: album.artworkData, maxDimension: 42)
                                            .frame(width: 42, height: 42)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(album.name)
                                                .font(
                                                    AroFont.fixed(
                                                        14,
                                                        weight: .semibold
                                                    )
                                                )
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Text(
                                                "\(album.artistName) · "
                                                    + "\(album.songs.count) songs"
                                            )
                                            .font(AroFont.fixed(12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedAlbumID == album.id
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
                                    selectedAlbumID == album.id
                                        ? .isSelected
                                        : []
                                )
                                .contextMenu {
                                    Button("Play Album") {
                                        playAlbum(album)
                                    }
                                    .disabled(album.songs.isEmpty)
                                    Divider()
                                    Button("Sync Album Data") {
                                        Task { await syncAlbumData(album.songs) }
                                    }
                                    Divider()
                                    Button("Metadata…") {
                                        editMetadata(
                                            MetadataEditorContext(
                                                scope: .album,
                                                songs: album.songs
                                            )
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                }
                .overlay {
                    if filteredAlbums.isEmpty {
                        ContentUnavailableView(
                            "No Matching Albums",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "Try a different album or artist name."
                            )
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
    private var albumDetail: some View {
        if let album = selectedAlbum {
            VStack(spacing: 0) {
                header(title: album.name, subtitle: album.summary)

                ScrollView {
                    LibraryAlbumSection(
                        name: album.name,
                        artistName: album.artistName,
                        artworkData: album.artworkData,
                        songs: album.songs,
                        playback: playback,
                        syncTrackData: syncTrackData,
                        editMetadata: editMetadata,
                        syncAlbumData: syncAlbumData
                    )
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)

                    if let loadRadio {
                        MoreLikeThisSection(
                            seed: collectionSeed(album.songs),
                            seedLabel: album.name,
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
                "No Albums Found",
                systemImage: "square.stack",
                description: Text(
                    "Add a music folder to browse albums."
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

    private func playAlbum(_ album: LibraryAlbum) {
        guard let firstSong = album.songs.first else { return }
        playback.play(song: firstSong, queue: album.songs)
    }

    /// Opens the browser on the album you're currently listening to rather than
    /// the top of an alphabetical list — see `ArtistsView.focusNowPlayingArtist`.
    private func focusNowPlayingAlbum() {
        if let nowPlayingAlbumID,
           albums.contains(where: { $0.id == nowPlayingAlbumID }) {
            selectedAlbumID = nowPlayingAlbumID
        }
        selectFirstAlbumIfNeeded()
    }

    private func selectFirstAlbumIfNeeded() {
        guard !albums.isEmpty else {
            selectedAlbumID = nil
            return
        }
        if !albums.contains(where: { $0.id == selectedAlbumID }) {
            selectedAlbumID = albums.first?.id
        }
    }

    private func selectFirstFilteredAlbumIfNeeded() {
        guard !filteredAlbums.isEmpty else { return }
        if !filteredAlbums.contains(where: { $0.id == selectedAlbumID }) {
            selectedAlbumID = filteredAlbums.first?.id
        }
    }

    private func moveBrowserSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down,
              !filteredAlbums.isEmpty else {
            return
        }
        let current = filteredAlbums.firstIndex {
            $0.id == selectedAlbumID
        } ?? 0
        let offset = direction == .down ? 1 : -1
        let next = min(
            max(current + offset, filteredAlbums.startIndex),
            filteredAlbums.index(before: filteredAlbums.endIndex)
        )
        selectedAlbumID = filteredAlbums[next].id
    }
}
