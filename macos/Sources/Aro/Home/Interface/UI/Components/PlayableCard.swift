import SwiftUI

/// Wraps a Home card (`MixCard`/`AlbumCard`/`PlaylistCard`) so it plays directly from
/// a hover-revealed play button — matching the familiar Apple Music/Spotify card
/// pattern — while the rest of the card still opens its detail view. The two actions
/// are separate sibling `Button`s layered in a `ZStack` (not one button nested inside
/// another, which SwiftUI won't hit-test independently): the play button occupies
/// only its own corner, so tapping it triggers playback, and tapping anywhere else on
/// the card opens detail.
///
/// The play button is always present in the hierarchy — only its opacity and hit
/// testing toggle with hover, rather than the button being conditionally inserted or
/// removed. Inserting/removing a view under the cursor mid-hover changes what's being
/// hit-tested at that exact point, which was flickering the hover state between
/// adjacent cards in a fast horizontal row (the appearing button would briefly steal
/// the hover, `onHover(false)` would fire on this card, the button would disappear
/// again, hover would land on the neighbour instead) — keeping the button's identity
/// stable avoids that churn entirely.
struct PlayableCard<Content: View>: View {
    let onSelect: () -> Void
    let onPlay: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        // Pinned top-trailing so it always lands over the artwork/gradient itself.
        // Bottom-trailing put it over the title/artist text on `AlbumCard`, whose
        // text block sits *below* its artwork — so the button's position drifted
        // between card types depending on how tall their text ran.
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                content()
            }
            .buttonStyle(.plain)

            Button(action: onPlay) {
                // Built from a real `Circle` plus a `play.fill` glyph rather than the
                // single `play.circle.fill` symbol: that symbol's triangle is a
                // *knockout* (transparent), so filling it white would let the artwork
                // show through the triangle instead of reading as a solid button.
                // `strokeBorder` (not `stroke`) draws wholly inside the circle's
                // bounds, so the hairline sits flush on the fill's edge.
                Circle()
                    .fill(.white)
                    .overlay {
                        Circle().strokeBorder(Color(white: 0.9), lineWidth: 0.5)
                    }
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AroTheme.violet)
                            // A play triangle centred geometrically reads as sitting
                            // slightly left, since its visual mass is off to one side.
                            .offset(x: 1)
                    }
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .padding(12)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
