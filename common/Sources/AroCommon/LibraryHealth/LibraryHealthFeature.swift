import Foundation

public struct LibraryHealthCopy: Identifiable, Hashable, Sendable {
    public let trackID: UUID
    public let path: String
    public let isAvailable: Bool
    public let codec: String
    public let sampleRate: Double?
    public let bitDepth: Int?
    public let bitrate: Double?
    public let fileSizeBytes: Int64

    public init(
        trackID: UUID,
        path: String,
        isAvailable: Bool,
        codec: String,
        sampleRate: Double?,
        bitDepth: Int?,
        bitrate: Double?,
        fileSizeBytes: Int64
    ) {
        self.trackID = trackID
        self.path = path
        self.isAvailable = isAvailable
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.fileSizeBytes = fileSizeBytes
    }

    public var id: String {
        "\(trackID.uuidString)|\(path)"
    }

    public var qualityScore: Double {
        let normalizedCodec = codec.lowercased()
        let lossless = [
            "flac", "alac", "apple lossless", "wav", "wave", "aiff"
        ].contains { normalizedCodec.contains($0) }
        return (lossless ? 1_000_000 : 0)
            + Double(bitDepth ?? 0) * 10_000
            + (sampleRate ?? 0)
            + (bitrate ?? 0) / 1_000
    }

    fileprivate var formatSignature: String {
        [
            codec.lowercased(),
            String(bitDepth ?? 0),
            String(Int((sampleRate ?? 0).rounded())),
            String(Int((bitrate ?? 0).rounded()))
        ].joined(separator: "|")
    }
}

public enum LibraryHealthRecommendationKind: String, Sendable {
    case exactDuplicate
    case alternateEncoding
    case moved
    case missing
}

public struct LibraryHealthRecommendation:
    Identifiable,
    Hashable,
    Sendable
{
    public let id: String
    public let kind: LibraryHealthRecommendationKind
    public let title: String
    public let artist: String
    public let reason: String
    public let copies: [LibraryHealthCopy]
    public let preferredCopyID: LibraryHealthCopy.ID?
    public let potentialSavingsBytes: Int64

    public init(
        id: String,
        kind: LibraryHealthRecommendationKind,
        title: String,
        artist: String,
        reason: String,
        copies: [LibraryHealthCopy],
        preferredCopyID: LibraryHealthCopy.ID?,
        potentialSavingsBytes: Int64
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artist = artist
        self.reason = reason
        self.copies = copies
        self.preferredCopyID = preferredCopyID
        self.potentialSavingsBytes = potentialSavingsBytes
    }
}

public struct LibraryHealthTrack: Sendable {
    public let id: UUID
    public let contentHash: String?
    public let title: String
    public let artist: String
    public let duration: TimeInterval?
    public let copies: [LibraryHealthCopy]

    public init(
        id: UUID,
        contentHash: String?,
        title: String,
        artist: String,
        duration: TimeInterval?,
        copies: [LibraryHealthCopy]
    ) {
        self.id = id
        self.contentHash = contentHash
        self.title = title
        self.artist = artist
        self.duration = duration
        self.copies = copies
    }
}

public struct LibraryHealthReport: Sendable {
    public var exactDuplicates: [LibraryHealthRecommendation]
    public var alternateEncodings: [LibraryHealthRecommendation]
    public var movedFiles: [LibraryHealthRecommendation]
    public var missingFiles: [LibraryHealthRecommendation]

    public init(
        exactDuplicates: [LibraryHealthRecommendation] = [],
        alternateEncodings: [LibraryHealthRecommendation] = [],
        movedFiles: [LibraryHealthRecommendation] = [],
        missingFiles: [LibraryHealthRecommendation] = []
    ) {
        self.exactDuplicates = exactDuplicates
        self.alternateEncodings = alternateEncodings
        self.movedFiles = movedFiles
        self.missingFiles = missingFiles
    }

    public var recommendationCount: Int {
        exactDuplicates.count
            + alternateEncodings.count
            + movedFiles.count
            + missingFiles.count
    }

    public var exactReclaimableBytes: Int64 {
        exactDuplicates.reduce(0) { $0 + $1.potentialSavingsBytes }
    }
}

public struct LibraryHealthAnalyzer: Sendable {
    public init() {}

    public func analyze(
        _ tracks: [LibraryHealthTrack]
    ) -> LibraryHealthReport {
        var report = LibraryHealthReport()
        classifyLocations(in: tracks, into: &report)
        classifyAlternateEncodings(in: tracks, into: &report)
        sortRecommendations(in: &report)
        return report
    }

    private func classifyLocations(
        in tracks: [LibraryHealthTrack],
        into report: inout LibraryHealthReport
    ) {
        for track in tracks {
            let available = track.copies.filter(\.isAvailable)
            let unavailable = track.copies.filter { !$0.isAvailable }

            if available.count > 1, let contentHash = track.contentHash {
                let copies = available.sorted {
                    $0.path.localizedStandardCompare($1.path)
                        == .orderedAscending
                }
                report.exactDuplicates.append(
                    LibraryHealthRecommendation(
                        id: "exact:\(contentHash)",
                        kind: .exactDuplicate,
                        title: track.title,
                        artist: track.artist,
                        reason: "Byte-for-byte identical content hash.",
                        copies: copies,
                        preferredCopyID: copies.first?.id,
                        potentialSavingsBytes: copies.dropFirst().reduce(0) {
                            $0 + $1.fileSizeBytes
                        }
                    )
                )
            }

            if !available.isEmpty, !unavailable.isEmpty {
                report.movedFiles.append(
                    LibraryHealthRecommendation(
                        id: "moved:\(track.id.uuidString)",
                        kind: .moved,
                        title: track.title,
                        artist: track.artist,
                        reason:
                            "An available copy matches \(unavailable.count) former location\(unavailable.count == 1 ? "" : "s").",
                        copies: available + unavailable,
                        preferredCopyID: available.first?.id,
                        potentialSavingsBytes: 0
                    )
                )
            } else if available.isEmpty, !unavailable.isEmpty {
                report.missingFiles.append(
                    LibraryHealthRecommendation(
                        id: "missing:\(track.id.uuidString)",
                        kind: .missing,
                        title: track.title,
                        artist: track.artist,
                        reason:
                            "No scanned location for this song is available.",
                        copies: unavailable,
                        preferredCopyID: nil,
                        potentialSavingsBytes: 0
                    )
                )
            }
        }
    }

    private func classifyAlternateEncodings(
        in tracks: [LibraryHealthTrack],
        into report: inout LibraryHealthReport
    ) {
        let availableTracks = tracks.filter {
            $0.copies.contains(where: \.isAvailable)
        }
        let metadataGroups = Dictionary(grouping: availableTracks) {
            metadataKey(title: $0.title, artist: $0.artist)
        }

        for (key, candidates) in metadataGroups
        where !key.isEmpty && candidates.count > 1 {
            var remaining = candidates.sorted {
                ($0.duration ?? 0) < ($1.duration ?? 0)
            }
            while let seed = remaining.first {
                remaining.removeFirst()
                let matches = remaining.filter {
                    guard let seedDuration = seed.duration,
                          let duration = $0.duration else {
                        return false
                    }
                    return abs(seedDuration - duration) <= 2
                }
                remaining.removeAll { candidate in
                    matches.contains { $0.id == candidate.id }
                }
                appendAlternateRecommendation(
                    for: [seed] + matches,
                    seed: seed,
                    to: &report
                )
            }
        }
    }

    private func appendAlternateRecommendation(
        for cluster: [LibraryHealthTrack],
        seed: LibraryHealthTrack,
        to report: inout LibraryHealthReport
    ) {
        guard cluster.count > 1 else {
            return
        }

        let copies = cluster.compactMap { track in
            track.copies
                .filter(\.isAvailable)
                .max { $0.qualityScore < $1.qualityScore }
        }
        let formatSignatures = Set(copies.map(\.formatSignature))
        guard copies.count > 1, formatSignatures.count > 1 else {
            return
        }

        let preferred = copies.max {
            $0.qualityScore < $1.qualityScore
        }
        let ids = cluster.map { $0.id.uuidString }.sorted()
        report.alternateEncodings.append(
            LibraryHealthRecommendation(
                id: "alternate:\(ids.joined(separator: ":"))",
                kind: .alternateEncoding,
                title: seed.title,
                artist: seed.artist,
                reason:
                    "Artist, title and duration match. Review before removing a lower-quality encoding.",
                copies: copies.sorted {
                    $0.qualityScore > $1.qualityScore
                },
                preferredCopyID: preferred?.id,
                potentialSavingsBytes:
                    copies
                    .filter { $0.id != preferred?.id }
                    .reduce(0) { $0 + $1.fileSizeBytes }
            )
        )
    }

    private func metadataKey(title: String, artist: String) -> String {
        let unknown = ["", "unknown track", "unknown artist"]
        let normalizedTitle = normalizedMetadata(title)
        let normalizedArtist = normalizedMetadata(artist)
        guard !unknown.contains(title.lowercased()),
              !unknown.contains(artist.lowercased()),
              !normalizedTitle.isEmpty,
              !normalizedArtist.isEmpty else {
            return ""
        }
        return "\(normalizedArtist)|\(normalizedTitle)"
    }

    private func normalizedMetadata(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }

    private func sortRecommendations(
        in report: inout LibraryHealthReport
    ) {
        report.exactDuplicates.sort(by: recommendationSort)
        report.alternateEncodings.sort(by: recommendationSort)
        report.movedFiles.sort(by: recommendationSort)
        report.missingFiles.sort(by: recommendationSort)
    }

    private func recommendationSort(
        _ lhs: LibraryHealthRecommendation,
        _ rhs: LibraryHealthRecommendation
    ) -> Bool {
        let artistOrder = lhs.artist.localizedStandardCompare(rhs.artist)
        if artistOrder != .orderedSame {
            return artistOrder == .orderedAscending
        }
        return lhs.title.localizedStandardCompare(rhs.title)
            == .orderedAscending
    }
}

public protocol LibraryHealthTrackQuerying: Sendable {
    func libraryHealthTracks() -> [LibraryHealthTrack]
}

public struct ReviewLibraryHealth: Sendable {
    private let tracks: any LibraryHealthTrackQuerying
    private let analyzer: LibraryHealthAnalyzer

    public init(
        tracks: any LibraryHealthTrackQuerying,
        analyzer: LibraryHealthAnalyzer = LibraryHealthAnalyzer()
    ) {
        self.tracks = tracks
        self.analyzer = analyzer
    }

    public func execute() -> LibraryHealthReport {
        analyzer.analyze(tracks.libraryHealthTracks())
    }
}
