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
    /// Track to find neighbours for. Song/playlist views pass whatever is playing;
    /// artist/album views pass a representative track from the collection on screen,
    /// since there the interesting question is "what sounds like *this record*", not
    /// "what sounds like whatever happens to be playing".
    let seed: Song?
    /// What the subtitle describes the seed as — a track title, or an artist/album
    /// name when the shelf represents a whole collection. Falls back to the seed's
    /// own title.
    var seedLabel: String?
    /// Song/playlist views sit above a long scrolling table where a permanent shelf
    /// costs real estate, so they let it be folded away. Artist/album views are
    /// short enough not to need it.
    var isCollapsible: Bool = false
    /// The full local catalog, needed because the hub answers with content hashes
    /// spanning the whole library rather than just the visible list.
    let allSongs: [Song]
    let loadRadio: (String) async -> ServerGeneratedPlaylist?
    let playback: PlaybackController

    @State private var similar: [Song] = []
    /// Persisted rather than view-local: this view is rebuilt on every navigation,
    /// so a plain `@State` would silently re-expand a shelf the listener had
    /// deliberately collapsed each time they changed screens.
    @AppStorage("moreLikeThis.expanded") private var isExpanded = true

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
                header
                if !isCollapsible || isExpanded {
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
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            // Definite height + priority so the shelf actually gets space in a
            // VStack shared with `AppKitSongTable`, an NSViewRepresentable that
            // otherwise takes every available point.
            .frame(height: isCollapsible && !isExpanded ? 58 : 214)
            .layoutPriority(1)
        }
    }

    /// The section title, with a disclosure control when the shelf can be folded.
    @ViewBuilder
    private var header: some View {
        let subtitle = (seedLabel ?? seed?.title).map { "Sounds like \($0)" }
            ?? "Measured from the audio"
        if isCollapsible {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SectionHeader(title: "More Like This", subtitle: subtitle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            SectionHeader(title: "More Like This", subtitle: subtitle)
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
