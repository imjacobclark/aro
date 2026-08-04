import Foundation
import AroCommon

enum EditableMetadataField: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case album
    case genre
    case releaseYear = "release_year"
    case trackNumber = "track_number"
    case discNumber = "disc_number"

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .releaseYear: "Release Year"
        case .trackNumber: "Track Number"
        case .discNumber: "Disc Number"
        }
    }

    var isNumeric: Bool {
        self == .releaseYear || self == .trackNumber || self == .discNumber
    }
}

struct MetadataCandidate: Hashable, Sendable {
    enum Source: String, CaseIterable, Sendable {
        case identified = "MusicBrainz / AcoustID"
        case file = "Original File"
        case library = "Aro Library"
    }

    let value: String
    let source: Source
    /// The artist this value belongs to when the candidate is artist-dependent
    /// (currently album suggestions). Identified values deliberately remain
    /// available regardless of the artist selected in the editor.
    let relatedArtist: String?

    init(
        value: String,
        source: Source,
        relatedArtist: String? = nil
    ) {
        self.value = value
        self.source = source
        self.relatedArtist = relatedArtist
    }
}

struct ArtworkCandidate: Hashable, Sendable {
    let data: Data
    let source: MetadataCandidate.Source
    let relatedArtist: String?
    let relatedAlbum: String?
}

struct TrackMetadataSnapshot: Sendable {
    let song: Song
    let effectiveValues: [EditableMetadataField: String]
    let manualFields: Set<EditableMetadataField>
    let candidates: [EditableMetadataField: [MetadataCandidate]]
    let artworkCandidates: [ArtworkCandidate]
    let manualArtworkSet: Bool

    init(
        song: Song,
        effectiveValues: [EditableMetadataField: String],
        manualFields: Set<EditableMetadataField>,
        candidates: [EditableMetadataField: [MetadataCandidate]],
        artworkCandidates: [ArtworkCandidate] = [],
        manualArtworkSet: Bool = false
    ) {
        self.song = song
        self.effectiveValues = effectiveValues
        self.manualFields = manualFields
        self.candidates = candidates
        self.artworkCandidates = artworkCandidates
        self.manualArtworkSet = manualArtworkSet
    }

    func candidates(
        for field: EditableMetadataField,
        selectedArtist: String
    ) -> [MetadataCandidate] {
        let available = candidates[field] ?? []
        guard field == .album else { return available }

        let selectedArtist = Self.normalizedArtist(selectedArtist)
        return available.filter { candidate in
            candidate.source == .identified
                || candidate.relatedArtist.map(Self.normalizedArtist) == selectedArtist
        }
    }

    private static func normalizedArtist(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func artworkCandidates(
        selectedArtist: String,
        selectedAlbum: String
    ) -> [ArtworkCandidate] {
        let artist = Self.normalizedArtist(selectedArtist)
        let album = Self.normalizedAlbum(selectedAlbum)
        return artworkCandidates.filter { candidate in
            candidate.source == .identified
                || (candidate.relatedArtist.map(Self.normalizedArtist) == artist
                    && candidate.relatedAlbum.map(Self.normalizedAlbum) == album)
        }
    }

    private static func normalizedAlbum(_ album: String) -> String {
        album.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct ManualMetadataEdit: Sendable {
    let field: EditableMetadataField
    /// `nil` deliberately clears an optional value. The presence of this edit,
    /// not the value, is what makes the field a golden-master override.
    let value: String?
}

struct ManualArtworkEdit: Hashable, Sendable {
    /// `nil` deliberately selects no artwork. The edit's presence makes artwork
    /// a golden master, mirroring nullable text metadata overrides.
    let data: Data?
}

enum MetadataEditingScope: Sendable {
    case track
    case album
    case artist
}

struct MetadataEditorContext: Identifiable, Sendable {
    let id = UUID()
    let scope: MetadataEditingScope
    let songs: [Song]
}

/// A cover offered by the hub rather than found in this Mac's own library.
///
/// The local library can only ever offer artwork it already holds — the file's embedded
/// image, the one cover identification settled on, and whatever other tracks happen to
/// carry. That misses almost everything the Cover Art Archive actually has: it is
/// populated per *release*, and MusicBrainz routinely carries one album as many releases,
/// so the pressing a track matched is often not the one anybody scanned. These candidates
/// come from the hub walking that out — every pressing of this album, and one cover from
/// each of the artist's other albums.
///
/// `thumbnail` is a small image for the picker grid. `fullImageURL` is resolved to real
/// bytes only when a listener chooses this candidate, so browsing a discography never
/// downloads full-resolution art for covers nobody picks.
struct HubArtworkCandidate: Hashable, Sendable, Identifiable {
    let thumbnail: Data
    let fullImageURL: String
    let origin: RemoteArtworkOrigin
    let album: String?

    var id: String { fullImageURL }
}
