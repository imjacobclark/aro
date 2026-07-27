import AroCommon
import SwiftUI

struct AlbumsView: View {
    let songs: [Song]
    @Bindable var playback: PlaybackController

    @State private var selectedAlbumID: LibraryAlbum.ID?
    @State private var searchText = ""

    private var albums: [LibraryAlbum] {
        AlbumLibrary.albums(from: songs)
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

    var body: some View {
        if albums.isEmpty {
            VStack(spacing: 0) {
                header(title: "Albums", subtitle: "0 albums")
                ContentUnavailableView(
                    "No Albums Found",
                    systemImage: "square.stack",
                    description: Text(
                        "Add a watched folder containing music to browse albums."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                albumList
                Divider()
                albumDetail
            }
            .task {
                selectFirstAlbumIfNeeded()
            }
            .onChange(of: albums.map(\.id)) {
                selectFirstAlbumIfNeeded()
            }
        }
    }

    private var albumList: some View {
        VStack(spacing: 0) {
            LibrarySearchField(
                prompt: "Search Albums",
                text: $searchText
            )

            Divider()

            List(filteredAlbums, selection: $selectedAlbumID) { album in
                HStack(spacing: 10) {
                    AlbumArtworkView(data: album.artworkData)
                        .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.name)
                            .font(AroFont.headline)
                            .lineLimit(1)
                        Text(album.artistName)
                            .font(AroFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .tag(album.id)
            }
            .listStyle(.sidebar)
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
        }
        .frame(minWidth: 205, idealWidth: 235, maxWidth: 270)
    }

    @ViewBuilder
    private var albumDetail: some View {
        if let album = selectedAlbum {
            VStack(spacing: 0) {
                header(title: album.name, subtitle: album.summary)

                ScrollView {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            AlbumArtworkView(data: album.artworkData)
                                .frame(width: 180, height: 180)

                            Text(album.artistName)
                                .font(AroFont.headline)
                                .lineLimit(2)
                                .help(album.artistName)
                        }
                        .frame(width: 180, alignment: .leading)

                        Divider()

                        AlbumSongList(
                            songs: album.songs,
                            playback: playback
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .padding(16)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                        .stroke(Color.primary.opacity(0.06))
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

    private func selectFirstAlbumIfNeeded() {
        guard !albums.isEmpty else {
            selectedAlbumID = nil
            return
        }
        if !albums.contains(where: { $0.id == selectedAlbumID }) {
            selectedAlbumID = albums.first?.id
        }
    }
}
