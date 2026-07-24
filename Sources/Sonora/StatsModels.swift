import Foundation

struct DailyListeningStat: Identifiable, Sendable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
}

struct RankedListeningStat: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let playCount: Int
}

struct RecentPlayStat: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let playedAt: Date
}

struct ListeningStats: Sendable {
    var totalSeconds: TimeInterval = 0
    var last30DaysSeconds: TimeInterval = 0
    var loggedPlays = 0
    var uniqueTracksPlayed = 0
    var currentStreak = 0
    var daily: [DailyListeningStat] = []
    var topTracks: [RankedListeningStat] = []
    var topArtists: [RankedListeningStat] = []
    var recent: [RecentPlayStat] = []
}

struct LibraryBreakdownStat: Identifiable, Sendable {
    let name: String
    let trackCount: Int
    let fileSizeBytes: Int64
    var id: String { name }
}

struct LibraryStats: Sendable {
    var trackCount = 0
    var albumCount = 0
    var artistCount = 0
    var totalDuration: TimeInterval = 0
    var fileSizeBytes: Int64 = 0
    var formats: [LibraryBreakdownStat] = []
    var genres: [LibraryBreakdownStat] = []
    var decades: [LibraryBreakdownStat] = []
}
