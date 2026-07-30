import AroCommon
import SwiftUI

struct ArtistsView: View {
    let songs: [Song]
    let playback: PlaybackController
    let syncTrackData: (Song) async -> Void

    @State private var selectedArtistID: LibraryArtist.ID?
    @State private var searchText = ""
    @FocusState private var isBrowserFocused: Bool

    private var artists: [LibraryArtist] {
        ArtistLibrary.artists(from: songs)
    }

    private var selectedArtist: LibraryArtist? {
        artists.first(where: { $0.id == selectedArtistID }) ?? artists.first
    }

    private var filteredArtists: [LibraryArtist] {
        artists.filter { FuzzySearch.matches(searchText, in: $0.name) }
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
            selectFirstArtistIfNeeded()
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
