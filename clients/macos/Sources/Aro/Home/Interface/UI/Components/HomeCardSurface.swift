import SwiftUI

/// Shared chrome for the redesigned Home cards (`MixCard`/`AlbumCard`/`PlaylistCard`) —
/// a deliberate step up from `.statsSurface()`'s flat 12pt/no-shadow convention (still
/// used as-is by Stats/Library Health): 16pt corners and a soft shadow, giving Home's
/// larger, more editorial cards a bit of depth without looking heavy.
extension View {
    func homeCardSurface(cornerRadius: CGFloat = 16) -> some View {
        background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }
}
