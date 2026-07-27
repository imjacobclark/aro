import AroCommon

import Foundation
import UniformTypeIdentifiers

protocol AudioFileRecognizing: Sendable {
    func isAudioFile(at url: URL, resourceType: UTType?) -> Bool
}

struct SystemAudioFileRecognizer: AudioFileRecognizing {
    func isAudioFile(at url: URL, resourceType: UTType?) -> Bool {
        let supportedExtensions: Set<String> = [
            "aac", "aif", "aiff", "alac", "flac", "m4a", "mp3",
            "oga", "ogg", "wav", "wave"
        ]
        let extensionType = UTType(filenameExtension: url.pathExtension)
        return supportedExtensions.contains(url.pathExtension.lowercased())
            || resourceType?.conforms(to: .audio) == true
            || extensionType?.conforms(to: .audio) == true
    }
}
