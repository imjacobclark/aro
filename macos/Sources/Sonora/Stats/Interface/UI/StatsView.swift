import Charts
import SonoraCommon
import SwiftUI

private enum StatsMode: String, CaseIterable {
    case listening = "Listening"
    case library = "Library"
}

struct StatsView: View {
    @Bindable var playback: PlaybackController
    let loadStatsDashboard: LoadStatsDashboard

    @State private var mode: StatsMode = .listening
    @State private var listening = ListeningStats()
    @State private var library = LibraryStats()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stats")
                            .font(SonoraFont.largeTitle)
                        Text(
                            mode == .listening
                                ? "Counts since you started using Sonora."
                                : "What’s in your library right now."
                        )
                        .font(SonoraFont.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer()
                    AppSettingsButton()
                }

                Picker("Stats View", selection: $mode) {
                    ForEach(StatsMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .padding(.leading, -2)

                if mode == .listening {
                    listeningView
                } else {
                    libraryView
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
        .task(id: mode) {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: playback.currentSong?.id) {
            refresh()
        }
        .onChange(of: playback.state) {
            refresh()
        }
    }

    private var listeningView: some View {
        VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170), spacing: 12)
                ],
                spacing: 12
            ) {
                StatCard(
                    label: "Total listening time",
                    value: compactDuration(listening.totalSeconds),
                    detail: "\(listening.loggedPlays) logged plays"
                )
                StatCard(
                    label: "Last 30 days",
                    value: compactDuration(listening.last30DaysSeconds),
                    detail: "\(listening.currentStreak)-day streak"
                )
                StatCard(
                    label: "Tracks played",
                    value: "\(listening.uniqueTracksPlayed)",
                    detail: library.trackCount > 0
                        ? "\(Int(Double(listening.uniqueTracksPlayed) / Double(library.trackCount) * 100))% of library"
                        : "No library tracks"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Daily Listening — Last 30 Days")
                    .font(SonoraFont.headline)

                Chart(listening.daily) { day in
                    BarMark(
                        x: .value("Day", day.date),
                        y: .value("Minutes", day.seconds / 60)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            gradient: SonoraTheme.orbitGradient,
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine(stroke: StrokeStyle(dash: [2, 3]))
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 180)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    mostPlayedTracks
                    mostPlayedArtists
                }
                VStack(alignment: .leading, spacing: 24) {
                    mostPlayedTracks
                    mostPlayedArtists
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Recently Played")
                    .font(SonoraFont.headline)
                if listening.recent.isEmpty {
                    EmptyStatsText(
                        text: "Nothing played yet. Start listening to populate this list."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(listening.recent) { play in
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .frame(width: 32, height: 32)
                                    .background(
                                        Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(play.title)
                                        .font(
                                            SonoraFont.textStyle(
                                                .body,
                                                weight: .semibold
                                            )
                                        )
                                        .lineLimit(1)
                                        .help(play.title)
                                    Text(play.subtitle)
                                        .font(SonoraFont.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .help(play.subtitle)
                                }
                                .layoutPriority(1)
                                Spacer()
                                Text(
                                    play.playedAt.formatted(
                                        .relative(presentation: .named)
                                    )
                                )
                                .font(SonoraFont.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            }
                            .padding(12)
                            if play.id != listening.recent.last?.id {
                                Divider()
                            }
                        }
                    }
                    .statsSurface()
                }
            }
        }
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 132), spacing: 12)
                ],
                spacing: 12
            ) {
                StatCard(label: "Tracks", value: "\(library.trackCount)")
                StatCard(label: "Albums", value: "\(library.albumCount)")
                StatCard(label: "Artists", value: "\(library.artistCount)")
                StatCard(
                    label: "Total duration",
                    value: compactDuration(library.totalDuration),
                    detail: formattedBytes(library.fileSizeBytes)
                )
            }

            Divider()

            BreakdownList(title: "Format Breakdown", values: library.formats)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    genreBreakdown
                    decadeBreakdown
                }
                VStack(alignment: .leading, spacing: 24) {
                    genreBreakdown
                    decadeBreakdown
                }
            }
        }
    }

    private var mostPlayedTracks: some View {
        RankedStatsList(
            title: "Most Played Tracks",
            values: listening.topTracks
        )
    }

    private var mostPlayedArtists: some View {
        RankedStatsList(
            title: "Most Played Artists",
            values: listening.topArtists
        )
    }

    private var genreBreakdown: some View {
        BreakdownList(title: "Top Genres", values: library.genres)
    }

    private var decadeBreakdown: some View {
        BreakdownList(title: "By Decade", values: library.decades)
    }

    private func refresh() {
        let dashboard = loadStatsDashboard.execute()
        listening = dashboard.listening
        library = dashboard.library
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes) m"
        }
        return "\(minutes / 60) h \(minutes % 60) m"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }
}
