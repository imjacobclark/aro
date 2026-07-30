import AroCommon

import Foundation

enum Destination: Hashable {
    case songs
    case artists
    case albums
    case stats
    case libraryHealth
    case settings
    case metadata
    case folder(UUID)
}
