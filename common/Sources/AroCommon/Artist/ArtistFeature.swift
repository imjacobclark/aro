import Foundation

public struct ArtistAlbum: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let songs: [Song]
    public let artworkData: Data?

    public init(
        id: String,
        name: String,
        songs: [Song],
        artworkData: Data?
    ) {
        self.id = id
        self.name = name
        self.songs = songs
        self.artworkData = artworkData
    }
}

public struct LibraryArtist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let albums: [ArtistAlbum]

    public init(id: String, name: String, albums: [ArtistAlbum]) {
        self.id = id
        self.name = name
        self.albums = albums
    }

    public var songs: [Song] {
        albums.flatMap(\.songs)
    }

    public var summary: String {
        let albumCount = albums.count
        let songCount = songs.count
        return "\(albumCount) \(albumCount == 1 ? "album" : "albums"), "
            + "\(songCount) \(songCount == 1 ? "song" : "songs"), "
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

public enum ArtistLibrary {
    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"

    public static func artists(from songs: [Song]) -> [LibraryArtist] {
        let songsByArtist = Dictionary(grouping: songs) { song in
            normalizedKey(displayArtist(for: song))
        }

        return songsByArtist
            .map { entry in
                let artistKey = entry.key
                let artistSongs = entry.value
                let artistName = preferredName(
                    artistSongs.map { displayArtist(for: $0) },
                    fallback: unknownArtist
                )
                let groupedAlbums = albums(
                    from: artistSongs,
                    artistKey: artistKey
                )

                return LibraryArtist(
                    id: artistKey,
                    name: artistName,
                    albums: groupedAlbums
                )
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func albums(
        from songs: [Song],
        artistKey: String
    ) -> [ArtistAlbum] {
        let songsByAlbum = Dictionary(grouping: songs) { song in
            normalizedKey(displayAlbum(for: song))
        }
        var albums: [ArtistAlbum] = []

        for (albumKey, albumSongs) in songsByAlbum {
            let sortedSongs = SongLibrary.sorted(albumSongs)
            let albumName = preferredName(
                albumSongs.map { displayAlbum(for: $0) },
                fallback: unknownAlbum
            )
            var artworkData: Data?
            for song in sortedSongs where artworkData == nil {
                artworkData = song.artworkData
            }
            albums.append(
                ArtistAlbum(
                    id: artistKey + "|" + albumKey,
                    name: albumName,
                    songs: sortedSongs,
                    artworkData: artworkData
                )
            )
        }

        return albums.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func displayArtist(for song: Song) -> String {
        displayName(song.artist, fallback: unknownArtist)
    }

    private static func displayAlbum(for song: Song) -> String {
        displayName(song.album, fallback: unknownAlbum)
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

    private static func normalizedKey(_ value: String) -> String {
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
