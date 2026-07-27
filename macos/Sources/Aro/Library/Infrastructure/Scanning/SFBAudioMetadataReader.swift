import Foundation
import AroCommon
import SFBAudioEngine

struct SFBAudioMetadataReader: AudioMetadataReading, @unchecked Sendable {
    func metadata(for url: URL) async -> AroCommon.AudioMetadata? {
        do {
            let file = try SFBAudioEngine.AudioFile(
                readingPropertiesAndMetadataFrom: url
            )
            let properties = file.properties
            return AudioMetadata(
                title: file.metadata.title,
                artist: file.metadata.artist,
                album: file.metadata.albumTitle,
                genre: file.metadata.genre,
                releaseYear: file.metadata.releaseDate.flatMap {
                    Int($0.prefix(4))
                },
                artworkData: file.metadata
                    .attachedPictures(ofType: .frontCover)
                    .first?
                    .imageData,
                duration: properties.duration,
                properties: AudioFileProperties(
                    codec: properties.formatName
                        ?? url.pathExtension.uppercased(),
                    sampleRate: properties.sampleRate,
                    bitDepth: properties.bitDepth,
                    channelCount: properties.channelCount.map(Int.init),
                    bitrate: properties.bitrate
                )
            )
        } catch {
            return nil
        }
    }
}
