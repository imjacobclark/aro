import AroCommon

import Foundation

enum Destination: Hashable {
    case songs
    case artists
    case albums
    case stats
    case libraryHealth
    case devices
    case folder(UUID)
}
