import Foundation

enum LibraryHealthRecommendationKind: String, Sendable {
    case exactDuplicate
    case alternateEncoding
    case moved
    case missing
}

struct LibraryHealthCopy: Identifiable, Hashable, Sendable {
    let trackID: UUID
    let path: String
    let isAvailable: Bool
    let codec: String
    let sampleRate: Double?
    let bitDepth: Int?
    let bitrate: Double?
    let fileSizeBytes: Int64

    var id: String {
        "\(trackID.uuidString)|\(path)"
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var formatLabel: String {
        var parts = [codec.uppercased()]
        if let bitDepth {
            parts.append("\(bitDepth)-bit")
        }
        if let sampleRate {
            let rate = (sampleRate / 1_000).formatted(
                .number.precision(.fractionLength(0...1))
            )
            parts.append("\(rate) kHz")
        } else if let bitrate {
            parts.append("\(Int(bitrate / 1_000)) kbps")
        }
        return parts.joined(separator: " · ")
    }

    var qualityScore: Double {
        let normalizedCodec = codec.lowercased()
        let lossless = [
            "flac", "alac", "apple lossless", "wav", "wave", "aiff"
        ].contains { normalizedCodec.contains($0) }
        return (lossless ? 1_000_000 : 0)
            + Double(bitDepth ?? 0) * 10_000
            + (sampleRate ?? 0)
            + (bitrate ?? 0) / 1_000
    }
}

struct LibraryHealthRecommendation: Identifiable, Hashable, Sendable {
    let id: String
    let kind: LibraryHealthRecommendationKind
    let title: String
    let artist: String
    let reason: String
    let copies: [LibraryHealthCopy]
    let preferredCopyID: LibraryHealthCopy.ID?
    let potentialSavingsBytes: Int64
}

struct LibraryHealthReport: Sendable {
    var exactDuplicates: [LibraryHealthRecommendation] = []
    var alternateEncodings: [LibraryHealthRecommendation] = []
    var movedFiles: [LibraryHealthRecommendation] = []
    var missingFiles: [LibraryHealthRecommendation] = []

    var recommendationCount: Int {
        exactDuplicates.count
            + alternateEncodings.count
            + movedFiles.count
            + missingFiles.count
    }

    var exactReclaimableBytes: Int64 {
        exactDuplicates.reduce(0) { $0 + $1.potentialSavingsBytes }
    }
}
