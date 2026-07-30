#if canImport(Testing)
import Foundation
import Testing
@testable import AroCommon

@Suite("Stats dashboard")
struct LoadStatsDashboardTests {
    @Test("Calculates a consecutive listening streak in the domain")
    func calculatesStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_722_470_400)
        let dates = [
            now,
            calendar.date(byAdding: .day, value: -1, to: now)!,
            calendar.date(byAdding: .day, value: -2, to: now)!
        ]

        #expect(
            ListeningStreakCalculator().streak(
                for: dates,
                now: now,
                calendar: calendar
            ) == 3
        )
    }

    @Test("Loads both read models through the application port")
    func loadsDashboard() async {
        let now = Date(timeIntervalSince1970: 1_722_470_400)
        let dashboard = await LoadStatsDashboard(
            stats: StubStatsQuery(now: now)
        ).execute(now: now)

        #expect(dashboard.listening.loggedPlays == 4)
        #expect(dashboard.listening.currentStreak == 1)
        #expect(dashboard.library.trackCount == 12)
    }
}

private struct StubStatsQuery: StatsQuerying {
    let now: Date

    func listeningStats(now: Date) -> ListeningStats {
        var stats = ListeningStats()
        stats.loggedPlays = 4
        stats.daily = [
            DailyListeningStat(date: self.now, seconds: 30)
        ]
        return stats
    }

    func libraryStats() -> LibraryStats {
        var stats = LibraryStats()
        stats.trackCount = 12
        return stats
    }
}
#endif
