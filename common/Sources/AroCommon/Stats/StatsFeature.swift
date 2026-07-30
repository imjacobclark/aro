import Foundation

public struct DailyListeningStat: Identifiable, Codable, Sendable {
    public let date: Date
    public let seconds: TimeInterval

    public init(date: Date, seconds: TimeInterval) {
        self.date = date
        self.seconds = seconds
    }

    public var id: Date { date }
}

public struct LibraryBreakdownStat: Identifiable, Codable, Sendable {
    public let name: String
    public let trackCount: Int
    public let fileSizeBytes: Int64

    public init(name: String, trackCount: Int, fileSizeBytes: Int64) {
        self.name = name
        self.trackCount = trackCount
        self.fileSizeBytes = fileSizeBytes
    }

    public var id: String { name }
}

public struct RankedListeningStat: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let playCount: Int

    public init(
        id: String,
        title: String,
        subtitle: String,
        playCount: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.playCount = playCount
    }
}

public struct RecentPlayStat: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let playedAt: Date

    public init(
        id: String,
        title: String,
        subtitle: String,
        playedAt: Date
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.playedAt = playedAt
    }
}

public struct ListeningStats: Codable, Sendable {
    public var totalSeconds: TimeInterval
    public var last30DaysSeconds: TimeInterval
    public var loggedPlays: Int
    public var uniqueTracksPlayed: Int
    public var currentStreak: Int
    public var daily: [DailyListeningStat]
    public var topTracks: [RankedListeningStat]
    public var topArtists: [RankedListeningStat]
    public var recent: [RecentPlayStat]

    public init(
        totalSeconds: TimeInterval = 0,
        last30DaysSeconds: TimeInterval = 0,
        loggedPlays: Int = 0,
        uniqueTracksPlayed: Int = 0,
        currentStreak: Int = 0,
        daily: [DailyListeningStat] = [],
        topTracks: [RankedListeningStat] = [],
        topArtists: [RankedListeningStat] = [],
        recent: [RecentPlayStat] = []
    ) {
        self.totalSeconds = totalSeconds
        self.last30DaysSeconds = last30DaysSeconds
        self.loggedPlays = loggedPlays
        self.uniqueTracksPlayed = uniqueTracksPlayed
        self.currentStreak = currentStreak
        self.daily = daily
        self.topTracks = topTracks
        self.topArtists = topArtists
        self.recent = recent
    }
}

public struct LibraryStats: Codable, Sendable {
    public var trackCount: Int
    public var albumCount: Int
    public var artistCount: Int
    public var totalDuration: TimeInterval
    public var fileSizeBytes: Int64
    public var formats: [LibraryBreakdownStat]
    public var genres: [LibraryBreakdownStat]
    public var decades: [LibraryBreakdownStat]

    public init(
        trackCount: Int = 0,
        albumCount: Int = 0,
        artistCount: Int = 0,
        totalDuration: TimeInterval = 0,
        fileSizeBytes: Int64 = 0,
        formats: [LibraryBreakdownStat] = [],
        genres: [LibraryBreakdownStat] = [],
        decades: [LibraryBreakdownStat] = []
    ) {
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.artistCount = artistCount
        self.totalDuration = totalDuration
        self.fileSizeBytes = fileSizeBytes
        self.formats = formats
        self.genres = genres
        self.decades = decades
    }
}

public struct ListeningStreakCalculator: Sendable {
    public init() {}

    public func streak(
        for dates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor),
           let yesterday = calendar.date(
               byAdding: .day,
               value: -1,
               to: cursor
           ) {
            cursor = yesterday
        }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(
                byAdding: .day,
                value: -1,
                to: cursor
            ) else {
                break
            }
            cursor = previous
        }
        return streak
    }
}

public protocol StatsQuerying: Sendable {
    func listeningStats(now: Date) -> ListeningStats
    func libraryStats() -> LibraryStats
}

public struct StatsDashboard: Codable, Sendable {
    public let listening: ListeningStats
    public let library: LibraryStats

    public init(listening: ListeningStats, library: LibraryStats) {
        self.listening = listening
        self.library = library
    }
}

public struct LoadStatsDashboard: Sendable {
    private let stats: any StatsQuerying
    private let streakCalculator: ListeningStreakCalculator

    public init(
        stats: any StatsQuerying,
        streakCalculator: ListeningStreakCalculator =
            ListeningStreakCalculator()
    ) {
        self.stats = stats
        self.streakCalculator = streakCalculator
    }

    /// Runs the underlying (synchronous, SQLite-backed) queries off the
    /// calling actor, so repeated callers such as a UI polling loop don't
    /// block the main thread.
    public func execute(now: Date = Date()) async -> StatsDashboard {
        let stats = stats
        let streakCalculator = streakCalculator
        return await Task.detached(priority: .utility) {
            var listening = stats.listeningStats(now: now)
            listening.currentStreak = streakCalculator.streak(
                for: listening.daily.filter { $0.seconds > 0 }.map(\.date),
                now: now
            )
            return StatsDashboard(
                listening: listening,
                library: stats.libraryStats()
            )
        }.value
    }
}
