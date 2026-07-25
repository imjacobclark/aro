import SonoraCommon

import AVFoundation
import Foundation

struct AVFoundationMetadataReader: AudioMetadataReading {
    func metadata(for url: URL) async -> AudioMetadata? {
        let asset = AVURLAsset(url: url)

        do {
            guard try await asset.load(.isPlayable) else {
                return nil
            }

            async let duration = asset.load(.duration)
            async let commonMetadata = asset.load(.commonMetadata)

            let loadedDuration = try await duration
            let loadedMetadata = try await commonMetadata

            let title = await stringValue(
                for: .commonIdentifierTitle,
                in: loadedMetadata
            )
            let artist = await stringValue(
                for: .commonIdentifierArtist,
                in: loadedMetadata
            )
            let artworkData = await dataValue(
                for: .commonIdentifierArtwork,
                in: loadedMetadata
            )

            return AudioMetadata(
                title: title,
                artist: artist,
                album: nil,
                genre: nil,
                releaseYear: nil,
                artworkData: artworkData,
                duration: loadedDuration.isNumeric
                    ? loadedDuration.seconds
                    : nil,
                properties: nil
            )
        } catch {
            return nil
        }
    }

    private func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        let item = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: identifier
        ).first

        guard let item else {
            return nil
        }

        let value = try? await item.load(.stringValue)
        return value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
    }

    private func dataValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> Data? {
        let item = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: identifier
        ).first
        guard let item else { return nil }
        return try? await item.load(.dataValue)
    }
}
