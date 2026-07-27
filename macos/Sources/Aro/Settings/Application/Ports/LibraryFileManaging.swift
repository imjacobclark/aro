import AroCommon

import Foundation

protocol LibraryFileManaging: Sendable {
    var libraryURL: URL { get }
    func exportLibrary(to destinationURL: URL) throws
}
