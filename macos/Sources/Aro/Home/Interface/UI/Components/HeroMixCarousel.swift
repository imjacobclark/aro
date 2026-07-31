import AroCommon
import SwiftUI

/// The "Hero Personal Mixes" row — larger `MixCard`s in a horizontally scrolling,
/// view-aligned carousel, since this is meant to read as the page's editorial
/// centerpiece rather than just another row (which is what the other sections use,
/// via a plain unsnapped horizontal `ScrollView`).
struct HeroMixCarousel: View {
    let playlists: [ServerGeneratedPlaylist]
    let onSelect: (ServerGeneratedPlaylist) -> Void
    let onPlay: (ServerGeneratedPlaylist) -> Void
    let onStartRadio: (ServerGeneratedPlaylist) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(playlists) { playlist in
                    PlayableCard(
                        onSelect: { onSelect(playlist) },
                        onPlay: { onPlay(playlist) }
                    ) {
                        MixCard(
                            playlist: playlist,
                            width: HomeCardMetrics.heroWidth,
                            height: HomeCardMetrics.heroHeight
                        )
                    }
                    .contextMenu {
                        Button("Play") { onPlay(playlist) }
                        Button("Start Radio") { onStartRadio(playlist) }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}
