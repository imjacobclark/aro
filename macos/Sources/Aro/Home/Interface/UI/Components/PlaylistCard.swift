import AroCommon
import SwiftUI

/// A gradient-cover tile for playlists that are a taste/vibe grouping rather than one
/// real artist/album/year (currently just `.mood`). Visually identical to `MixCard`
/// (same edge-to-edge gradient, overlaid title/subtitle, shared card size) — kept as
/// its own named type since it represents a distinct kind of playlist even though
/// today it shares `MixCard`'s rendering.
struct PlaylistCard: View {
    let playlist: ServerGeneratedPlaylist

    var body: some View {
        MixCard(playlist: playlist)
    }
}
