import AroCommon
import SwiftUI

/// An abstract, on-brand "generated cover" for algorithmic playlists that don't
/// correspond to one real-world artist/album/year (Heavy Rotation, Daily Mix, Workout
/// Mix, mood mixes, …) — matching how Apple Music/Spotify style their own "Made for
/// You" mixes with bold gradient art rather than a grid of song thumbnails, which
/// would otherwise just repeat whatever album happens to dominate the mix. Built from
/// `AroTheme.orbitGradient` plus a couple of offset rings — a nod to the app icon's
/// own "orbital ring" (see `AroTheme`'s doc comment) — varied deterministically per
/// playlist id so different mixes don't all look identical.
///
/// Purely the gradient/rings/icon — no corner clipping or border of its own. `MixCard`
/// (the only caller) applies a single clip + corner radius to the whole card (gradient
/// plus its title/subtitle text overlay), so the gradient reaches the card's true edge
/// rather than sitting inside a separate bordered frame.
struct GeneratedPlaylistCoverView: View {
    let playlist: ServerGeneratedPlaylist
    var width: CGFloat = 146
    /// `nil` renders a square (`height == width`) — the shape most callers want.
    var height: CGFloat?

    private var resolvedHeight: CGFloat { height ?? width }
    /// Rings/icon are sized off the smaller dimension so they stay proportional
    /// (rather than stretching) when the card isn't square.
    private var proportionalSize: CGFloat { min(width, resolvedHeight) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: proportionalSize * 0.09)
                .frame(width: proportionalSize * 1.3)
                .offset(x: proportionalSize * 0.32, y: -proportionalSize * 0.34)
                .rotationEffect(.degrees(rotationDegrees))

            Circle()
                .stroke(Color.white.opacity(0.24), lineWidth: proportionalSize * 0.05)
                .frame(width: proportionalSize * 0.85)
                .offset(x: proportionalSize * 0.3, y: -proportionalSize * 0.28)
                .rotationEffect(.degrees(rotationDegrees + 55))

            Image(systemName: symbolName)
                .font(.system(size: proportionalSize * 0.3, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .frame(width: width, height: resolvedHeight)
        .clipped()
    }

    /// A stable (not Swift's per-process-randomized `Hasher`) hash of the playlist id,
    /// so a given playlist's look is consistent across refreshes and app relaunches,
    /// while still varying from one playlist to the next.
    private var seed: Int {
        var hash = 5_381
        for byte in playlist.id.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }

    private var rotationDegrees: Double {
        Double(seed % 360)
    }

    private var gradientColors: [Color] {
        let palette = [AroTheme.violet, AroTheme.coral, AroTheme.amber]
        let start = seed % palette.count
        return (0..<palette.count).map { palette[(start + $0) % palette.count] }
    }

    private var symbolName: String {
        if playlist.kind == .mood { return "sparkles" }
        if playlist.id.hasPrefix("workout") { return "bolt.fill" }
        if playlist.id.hasPrefix("wind-down") { return "moon.stars.fill" }
        if playlist.id.hasPrefix("daily-mix") { return "shuffle" }
        if playlist.id.hasPrefix("radio") { return "dot.radiowaves.left.and.right" }
        if playlist.id.hasPrefix("lost-album") { return "archivebox.fill" }
        if playlist.id == "time-capsule" { return "hourglass" }
        switch playlist.id {
        case "heavy-rotation": return "flame.fill"
        case "deep-cuts": return "magnifyingglass"
        case "forgotten-favourites": return "clock.arrow.circlepath"
        case "fresh-finds": return "leaf.fill"
        case "morning-rotation": return "sunrise.fill"
        case "late-night": return "moon.fill"
        case "recently-loved": return "heart.fill"
        default: return "waveform"
        }
    }
}
