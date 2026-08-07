import Foundation

@main
struct StatsDomainChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_722_470_400)
        let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        )!

        precondition(
            ListeningStreakCalculator().streak(
                for: [now, yesterday],
                now: now,
                calendar: calendar
            ) == 2
        )

        let dashboard = LoadStatsDashboard(
            stats: StandaloneStatsQuery(now: now)
        ).execute(now: now)
        precondition(dashboard.listening.loggedPlays == 3)
        precondition(dashboard.listening.currentStreak == 1)
        precondition(dashboard.library.trackCount == 9)

        print("Stats domain checks passed")
    }
}

private struct StandaloneStatsQuery: StatsQuerying {
    let now: Date

    func listeningStats(now: Date) -> ListeningStats {
        var stats = ListeningStats()
        stats.loggedPlays = 3
        stats.daily = [
            DailyListeningStat(date: self.now, seconds: 15)
        ]
        return stats
    }

    func libraryStats() -> LibraryStats {
        var stats = LibraryStats()
        stats.trackCount = 9
        return stats
    }
}
