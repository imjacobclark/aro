import AroCommon
import SwiftUI

struct ArtistsView: View {
    let songs: [Song]
    @Bindable var playback: PlaybackController

    @State private var selectedArtistID: LibraryArtist.ID?
    @State private var searchText = ""

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
        if artists.isEmpty {
            VStack(spacing: 0) {
                header(title: "Artists", subtitle: "0 artists")
                ContentUnavailableView(
                    "No Artists Found",
                    systemImage: "music.mic",
                    description: Text(
                        "Add a watched folder containing music to browse artists and albums."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                artistList
                Divider()
                artistDetail
            }
            .task {
                selectFirstArtistIfNeeded()
            }
            .onChange(of: artists.map(\.id)) {
                selectFirstArtistIfNeeded()
            }
        }
    }

    private var artistList: some View {
        VStack(spacing: 0) {
            LibrarySearchField(
                prompt: "Search Artists",
                text: $searchText
            )

            Divider()

            List(filteredArtists, selection: $selectedArtistID) { artist in
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(AroFont.headline)
                        .lineLimit(1)
                    Text("\(artist.albums.count) albums · \(artist.songs.count) songs")
                        .font(AroFont.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 3)
                .tag(artist.id)
            }
            .listStyle(.sidebar)
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
        .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
    }

    @ViewBuilder
    private var artistDetail: some View {
        if let artist = selectedArtist {
            VStack(spacing: 0) {
                header(title: artist.name, subtitle: artist.summary)

                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(artist.albums) { album in
                            AlbumRow(
                                album: album,
                                playback: playback
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func header(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AroFont.largeTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)

                Text(subtitle)
                    .font(AroFont.subheadline)
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
}

private struct AlbumRow: View {
    let album: ArtistAlbum
    @Bindable var playback: PlaybackController

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                AlbumArtworkView(data: album.artworkData)
                    .frame(width: 132, height: 132)

                Text(album.name)
                    .font(AroFont.headline)
                    .lineLimit(2)
                    .help(album.name)

                Text("\(album.songs.count) \(album.songs.count == 1 ? "song" : "songs")")
                    .font(AroFont.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 132, alignment: .leading)

            Divider()

            AlbumSongList(songs: album.songs, playback: playback)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        }
    }
}
