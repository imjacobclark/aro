import AroCommon

import Foundation

/// The hub's `/v1/library/health` payload, decoded into the shared report the view already
/// renders.
///
/// The analysis itself lives on the hub — see `aro-server`'s `library_health` module. That
/// is not an arbitrary split: library health is entirely a question about files, and this
/// app only ever scanned the copies on its own disk. A Mac used as a remote client of a hub
/// therefore had almost no local file locations and saw almost nothing, while the hub had
/// the complete picture all along.
struct HubLibraryHealthReport: Decodable {
    let exactDuplicates: [Recommendation]
    let alternateEncodings: [Recommendation]
    let movedFiles: [Recommendation]
    let missingFiles: [Recommendation]
    let fragmentedFolders: [Recommendation]

    enum CodingKeys: String, CodingKey {
        case exactDuplicates = "exact_duplicates"
        case alternateEncodings = "alternate_encodings"
        case movedFiles = "moved_files"
        case missingFiles = "missing_files"
        case fragmentedFolders = "fragmented_folders"
    }

    struct Recommendation: Decodable {
        let id: String
        let kind: String
        let title: String
        let artist: String
        let reason: String
        let copies: [Copy]
        let preferredCopyID: String?
        let potentialSavingsBytes: Int64

        enum CodingKeys: String, CodingKey {
            case id, kind, title, artist, reason, copies
            case preferredCopyID = "preferred_copy_id"
            case potentialSavingsBytes = "potential_savings_bytes"
        }
    }

    struct Copy: Decodable {
        let trackID: String
        let path: String
        let available: Bool
        let codec: String
        let sampleRate: Double?
        let bitDepth: Int?
        let bitrate: Double?
        let fileSizeBytes: Int64

        enum CodingKeys: String, CodingKey {
            case trackID = "track_id"
            case path, available, codec, bitrate
            case sampleRate = "sample_rate"
            case bitDepth = "bit_depth"
            case fileSizeBytes = "file_size_bytes"
        }
    }

    var asReport: LibraryHealthReport {
        LibraryHealthReport(
            exactDuplicates: exactDuplicates.map(\.asRecommendation),
            alternateEncodings: alternateEncodings.map(\.asRecommendation),
            movedFiles: movedFiles.map(\.asRecommendation),
            missingFiles: missingFiles.map(\.asRecommendation),
            fragmentedFolders: fragmentedFolders.map(\.asRecommendation)
        )
    }
}

private extension HubLibraryHealthReport.Recommendation {
    var asRecommendation: LibraryHealthRecommendation {
        LibraryHealthRecommendation(
            id: id,
            // A hub newer than this build can name a kind it has never heard of. Falling
            // back keeps the row visible and readable rather than dropping a finding
            // silently — the listener can still act on the reason text.
            kind: LibraryHealthRecommendationKind(rawValue: camelCased(kind))
                ?? .exactDuplicate,
            title: title,
            artist: artist,
            reason: reason,
            copies: copies.map(\.asCopy),
            preferredCopyID: preferredCopyID,
            potentialSavingsBytes: potentialSavingsBytes
        )
    }

    /// The hub serialises its enum snake_case; `LibraryHealthRecommendationKind` is
    /// camelCase.
    private func camelCased(_ value: String) -> String {
        let parts = value.split(separator: "_").map(String.init)
        guard let first = parts.first else { return value }
        return ([first] + parts.dropFirst().map(\.capitalized)).joined()
    }
}

private extension HubLibraryHealthReport.Copy {
    var asCopy: LibraryHealthCopy {
        LibraryHealthCopy(
            // The hub identifies tracks by its own UUID; a client that cannot parse one
            // still needs a stable, distinct id, and the path already provides it.
            trackID: UUID(uuidString: trackID) ?? UUID(),
            path: path,
            isAvailable: available,
            codec: codec,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            bitrate: bitrate,
            fileSizeBytes: fileSizeBytes
        )
    }
}
