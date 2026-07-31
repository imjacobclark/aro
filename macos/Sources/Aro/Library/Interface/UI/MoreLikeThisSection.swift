import AroCommon
import SwiftUI

/// A "More Like This" shelf: a horizontal row of tracks the hub considers similar to
/// a seed track, measured from the audio itself (tempo/energy/brightness/MFCC/chroma
/// — see `aro-server`'s `playlists::radio`) rather than from tags or listening
/// history. Appended below a track list so the DSP work is reachable while browsing
/// the library, not only from Home's generated playlists.
///
/// Renders nothing at all when there's no seed, no reachable hub, or the seed hasn't
/// been analyzed yet. That silence is deliberate: this is a discovery affordance, and
/// an empty shelf or an error row would be worse than simply not appearing.
struct MoreLikeThisSection: View {
    /// Track to find neighbours for. Callers pass the currently playing track when
    /// there is one, falling back to the first track on screen.
    let seed: Song?
    /// The full local catalog, needed because the hub answers with content hashes
    /// spanning the whole library rather than just the visible list.
    let allSongs: [Song]
    let loadRadio: (String) async -> ServerGeneratedPlaylist?
    let playback: PlaybackController

    @State private var similar: [Song] = []

    var body: some View {
        content
            // Keyed on the seed so switching tracks (or views) reloads rather than
            // leaving a stale shelf describing something no longer on screen.
            .task(id: seed?.contentHash) {
                await reload()
            }
    }

    /// Always resolves to a *real* view, collapsing to zero height when there's
    /// nothing to show rather than to nothing at all. An `if` that produces an empty
    /// view in its only branch gives SwiftUI nothing to place, so the `.task` above
    /// never runs — and since the task is what populates `similar`, the shelf would
    /// stay empty forever waiting on a load that could never start.
    @ViewBuilder
    private var content: some View {
        if similar.isEmpty {
            Color.clear.frame(height: 0)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                SectionHeader(
                    title: "More Like This",
                    subtitle: seed.map { "Sounds like \($0.title)" }
                        ?? "Measured from the audio"
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(similar) { song in
                            Button {
                                playback.play(song: song, queue: similar)
                            } label: {
                                tile(song)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            // Definite height + priority so the shelf actually gets space in a
            // VStack shared with `AppKitSongTable`, an NSViewRepresentable that
            // otherwise takes every available point.
            .frame(height: 214)
            .layoutPriority(1)
        }
    }

    private func reload() async {
        guard let contentHash = seed?.contentHash else {
            similar = []
            return
        }
        guard let station = await loadRadio(contentHash) else {
            similar = []
            return
        }
        let songsByHash = Dictionary(
            allSongs.compactMap { song in
                song.contentHash.map { ($0, song) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // The station always leads with its own seed (see `playlists::radio`), which
        // would be a confusing first card in a row headed "more like *this*".
        similar = station.contentHashes
            .filter { $0 != contentHash }
            .compactMap { songsByHash[$0] }
    }

    private func tile(_ song: Song) -> some View {
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
}
