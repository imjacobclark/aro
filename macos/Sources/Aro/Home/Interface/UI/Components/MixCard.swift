import AroCommon
import SwiftUI

/// A "made for you" mix tile: `GeneratedPlaylistCoverView`'s abstract gradient cover
/// fills the *entire* card edge to edge — no separate grey background/border framing
/// it — with a bottom scrim and title/subtitle overlaid directly on the gradient. Used
/// for playlists that don't correspond to one real artist/album/year — the curated
/// "recipe" mixes (Heavy Rotation, Deep Cuts, Time Capsule, Replay, …) — where a
/// mosaic of song artwork would just repeat whatever album happens to dominate the
/// mix. The hover-to-play affordance lives in `PlayableCard`, which wraps every Home
/// card uniformly rather than being baked into this one.
struct MixCard: View {
    let playlist: ServerGeneratedPlaylist
    var width: CGFloat = HomeCardMetrics.width
    var height: CGFloat = HomeCardMetrics.height

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeneratedPlaylistCoverView(playlist: playlist, width: width, height: height)

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(AroFont.textStyle(.title3, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(AroFont.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            .padding(16)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
