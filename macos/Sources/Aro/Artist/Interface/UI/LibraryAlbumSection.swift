import AroCommon
import SwiftUI

struct LibraryAlbumSection: View {
    let name: String
    let artistName: String?
    let artworkData: Data?
    let songs: [Song]
    let playback: PlaybackController
    let syncTrackData: (Song) async -> Void
    var syncAlbumData: (([Song]) async -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(name)
                    .font(AroFont.fixed(18, weight: .semibold))
                    .lineLimit(1)
                    .help(name)

                Spacer(minLength: 12)

                Menu {
                    Button("Play Album", systemImage: "play.fill") {
                        playAlbum()
                    }
                    .disabled(songs.isEmpty)

                    if let syncAlbumData {
                        Divider()
                        Button(
                            "Sync Album Data",
                            systemImage: "arrow.triangle.2.circlepath"
                        ) {
                            Task { await syncAlbumData(songs) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Album actions")
                .accessibilityLabel("\(name) actions")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()
                .overlay(AroTheme.hairline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    albumMetadata
                        .frame(width: 210, alignment: .leading)

                    Divider()
                        .overlay(AroTheme.hairline)

                    songList
                        .frame(minWidth: 220, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 0) {
                    albumMetadata
                    Divider()
                        .overlay(AroTheme.hairline)
                    songList
                }
            }
        }
        .background(AroTheme.albumSurface)
        .clipShape(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(AroTheme.hairline)
        }
        .contextMenu {
            Button("Play Album") {
                playAlbum()
            }
            .disabled(songs.isEmpty)
        }
    }

    private var albumMetadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(data: artworkData, maxDimension: 178)
                .frame(width: 178, height: 178)
                .padding(.bottom, 4)

            if let artistName {
                Text(artistName)
                    .font(AroFont.fixed(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(songSummary)
                .font(AroFont.fixed(12))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let releaseYear {
                Text(String(releaseYear))
                    .font(AroFont.fixed(12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var songList: some View {
        AlbumSongList(
            songs: songs,
            playback: playback,
            syncTrackData: syncTrackData
        )
        .padding(.vertical, 4)
    }

    private var songSummary: String {
        let count = songs.count
        let totalSeconds = songs.compactMap(\.duration).reduce(0, +)
        let minutes = max(0, Int(totalSeconds / 60))
        return "\(count) \(count == 1 ? "song" : "songs") · \(minutes) min"
    }

    private var releaseYear: Int? {
        songs.compactMap(\.releaseYear).sorted().first
    }

    private func playAlbum() {
        guard let firstSong = songs.first else { return }
        playback.play(song: firstSong, queue: songs)
    }
}
