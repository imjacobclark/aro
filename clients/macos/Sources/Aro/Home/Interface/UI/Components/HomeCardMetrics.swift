import SwiftUI

/// Shared sizing for every Home card type so a row mixing several of them (e.g.
/// "Jump Back In" mixing an `AlbumCard` with a `MixCard`) lines up rather than
/// showing inconsistently sized tiles. `height` matches `AlbumCard`'s natural
/// content height (168pt artwork + 12pt spacing + a two-line text block, sitting
/// directly on the page background with no card chrome of its own) — `MixCard`
/// matches that height even though its own gradient-cover-plus-overlaid-text
/// structure doesn't naturally need it, so the two line up in a mixed row.
/// `PlaylistCard` is the one exception (it delegates to `MixCard`'s own sizing
/// rather than this shared height) since it never appears alongside the others.
enum HomeCardMetrics {
    static let artworkSide: CGFloat = 168
    static let width: CGFloat = 196
    static let height: CGFloat = 214

    /// The Hero carousel's cards are deliberately bigger — this is the page's
    /// editorial centerpiece, not just another row.
    static let heroWidth: CGFloat = 240
    static let heroHeight: CGFloat = 300
}
