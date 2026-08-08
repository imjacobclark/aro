import AroCommon

import Foundation

enum Destination: Hashable {
    case home
    case songs
    /// Everything hearted, in one place. Favourites are also what the hub builds its
    /// Favorites Mix and "recently loved" playlists from, so they earn a destination
    /// rather than living only as a flag on a row.
    case favourites
    case artists
    case albums
    case stats
    case libraryHealth
    case settings
    case metadata
    case folder(UUID)
}
