import Foundation

public struct LibraryAlbum: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let artistName: String
    public let songs: [Song]
    public let artworkData: Data?

    public init(
        id: String,
        name: String,
        artistName: String,
        songs: [Song],
        artworkData: Data?
    ) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.songs = songs
        self.artworkData = artworkData
    }

    public var summary: String {
        let songCount = songs.count
        return "\(artistName) · "
            + "\(songCount) \(songCount == 1 ? "song" : "songs") · "
            + Self.formattedDuration(songs.compactMap(\.duration).reduce(0, +))
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days) \(days == 1 ? "day" : "days"), \(hours) hrs"
        }
        if hours > 0 {
            return "\(hours) \(hours == 1 ? "hr" : "hrs"), "
                + "\(minutes) \(minutes == 1 ? "min" : "mins")"
        }
        return "\(totalMinutes) \(totalMinutes == 1 ? "min" : "mins")"
    }
}

public enum AlbumLibrary {
    public static func albums(from songs: [Song]) -> [LibraryAlbum] {
        let grouped = Dictionary(grouping: songs) { song in
            normalized(displayArtist(song)) + "|" + normalized(displayAlbum(song))
        }
        var albums: [LibraryAlbum] = []

        for (id, albumSongs) in grouped {
            let sortedSongs = SongLibrary.albumSorted(albumSongs)
            var artworkData: Data?
            for song in sortedSongs where artworkData == nil {
                artworkData = song.artworkData
            }

            albums.append(
                LibraryAlbum(
                    id: id,
                    name: preferredName(
                        albumSongs.map(displayAlbum),
                        fallback: ArtistLibrary.unknownAlbum
                    ),
                    artistName: preferredName(
                        albumSongs.map(displayArtist),
                        fallback: ArtistLibrary.unknownArtist
                    ),
                    songs: sortedSongs,
                    artworkData: artworkData
                )
            )
        }

        return albums.sorted {
            let albumOrder = $0.name.localizedStandardCompare($1.name)
            if albumOrder != .orderedSame {
                return albumOrder == .orderedAscending
            }
            return $0.artistName.localizedStandardCompare($1.artistName)
                == .orderedAscending
        }
    }

    private static func displayArtist(_ song: Song) -> String {
        displayName(song.artist, fallback: ArtistLibrary.unknownArtist)
    }

    private static func displayAlbum(_ song: Song) -> String {
        displayName(song.album, fallback: ArtistLibrary.unknownAlbum)
    }

    private static func displayName(
        _ value: String?,
        fallback: String
    ) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—" else { return fallback }
        return trimmed
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func preferredName(
        _ names: [String],
        fallback: String
    ) -> String {
        names.first(where: { $0 != fallback }) ?? fallback
    }
}
