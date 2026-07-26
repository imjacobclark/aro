import SonoraCommon

import Foundation

struct LibraryHealthTrackMapper: Sendable {
    func map(_ record: LibraryHealthTrackRecord) -> LibraryHealthTrack? {
        guard let trackID = UUID(uuidString: record.id) else {
            return nil
        }

        let copies = record.copies.map {
            LibraryHealthCopy(
                trackID: trackID,
                path: $0.path,
                isAvailable: $0.isAvailable,
                codec: $0.codec ?? "Unknown",
                sampleRate: $0.sampleRate,
                bitDepth: $0.bitDepth,
                bitrate: $0.bitrate,
                fileSizeBytes: $0.fileSizeBytes
            )
        }
        return LibraryHealthTrack(
            id: trackID,
            contentHash: record.contentHash,
            title: record.title ?? "Unknown Song",
            artist: record.artist ?? "Unknown Artist",
            duration: record.duration,
            copies: copies
        )
    }
}
