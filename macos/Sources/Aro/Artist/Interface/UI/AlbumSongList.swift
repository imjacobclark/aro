import AroCommon
import SwiftUI

struct AlbumSongList: View {
    let songs: [Song]
    @Bindable var playback: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                Button {
                    playback.play(song: song, queue: songs)
                } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(AroFont.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 22, alignment: .trailing)

                        if playback.currentSong?.id == song.id {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Currently playing")
                        }

                        Text(song.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(song.formattedDuration)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(song.title)")

                if index < songs.count - 1 {
                    Divider()
                }
            }
        }
    }
}
