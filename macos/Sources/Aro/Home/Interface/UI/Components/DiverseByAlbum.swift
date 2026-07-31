import AroCommon

extension Array where Element == Song {
    /// Picks up to `count` songs, round-robining across distinct albums (one song
    /// from each album in turn, then a second from each that still has one, and so
    /// on) — used wherever Home shows several of a playlist's songs side by side (a
    /// track row's horizontal scroll) so it doesn't cluster several tiles from the
    /// same album together when a playlist happens to be dominated by one or two
    /// albums (e.g. "More From X" for an artist you've mostly been playing one record
    /// by lately). A simple "distinct albums first, then dump whatever's left in
    /// original order" pass isn't enough here — the leftover tail can itself be a run
    /// of the same album repeated, which is exactly the "not shuffled enough" look
    /// this replaces. Playback ordering is untouched by this — callers use it only
    /// for *which songs to display*, not for the queue actually handed to
    /// `PlaybackController`.
    func diverseByAlbum(count: Int) -> [Element] {
        var buckets: [String: [Element]] = [:]
        var albumOrder: [String] = []
        for song in self {
            let albumKey = song.album.flatMap { $0.isEmpty ? nil : $0 } ?? song.title
            if buckets[albumKey] == nil {
                albumOrder.append(albumKey)
            }
            buckets[albumKey, default: []].append(song)
        }

        var result: [Element] = []
        var round = 0
        while result.count < count {
            var madeProgress = false
            for key in albumOrder {
                guard result.count < count else { break }
                guard let bucket = buckets[key], round < bucket.count else { continue }
                result.append(bucket[round])
                madeProgress = true
            }
            guard madeProgress else { break }
            round += 1
        }
        return result
    }
}
