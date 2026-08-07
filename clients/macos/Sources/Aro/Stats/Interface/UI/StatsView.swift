import Charts
import AroCommon
import SwiftUI

private enum StatsMode: String, CaseIterable {
    case listening = "Listening"
    case library = "Library"
}

struct StatsView: View {
    let playback: PlaybackController
    let loadStatsDashboard: LoadStatsDashboard
    let serverDashboard: StatsDashboard?

    @State private var mode: StatsMode = .listening
    @State private var listening = ListeningStats()
    @State private var library = LibraryStats()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stats")
                            .font(AroFont.largeTitle)
                        Text(
                            mode == .listening
                                ? "Counts since you started using Aro."
                                : "What’s in your library right now."
                        )
                        .font(AroFont.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer()
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
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: playback.currentSong?.id) {
            Task { await refresh() }
        }
        .onChange(of: playback.state) {
            Task { await refresh() }
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
                    detail: listening.currentStreak == 0
                        ? "No listening streak yet"
                        : "\(listening.currentStreak)-day streak"
                )
                StatCard(
                    label: "Songs played",
                    value: "\(listening.uniqueTracksPlayed)",
                    detail: library.trackCount > 0
                        ? "\(Int(Double(listening.uniqueTracksPlayed) / Double(library.trackCount) * 100))% of library"
                        : "No library songs"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Daily Listening — Last 30 Days")
                    .font(AroFont.headline)

                if listening.daily.allSatisfy({ $0.seconds == 0 }) {
                    ContentUnavailableView(
                        "No Listening Yet",
                        systemImage: "waveform",
                        description: Text(
                            "Your daily listening history will appear here."
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                } else {
                    Chart(listening.daily) { day in
                        BarMark(
                            x: .value("Day", day.date),
                            y: .value("Minutes", day.seconds / 60)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                gradient: AroTheme.orbitGradient,
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) {
                            AxisGridLine(stroke: StrokeStyle(dash: [2, 3]))
                            AxisValueLabel(
                                format: .dateTime.day().month(.abbreviated)
                            )
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
                    .font(AroFont.headline)
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
                                            AroFont.textStyle(
                                                .body,
                                                weight: .semibold
                                            )
                                        )
                                        .lineLimit(1)
                                        .help(play.title)
                                    Text(play.subtitle)
                                        .font(AroFont.caption)
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
                                .font(AroFont.caption)
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

    /// What the library *is*, rather than how big it is: how much survived encoding
    /// intact, how much is better than CD, and how compressed the masters are. Hidden
    /// entirely when the hub doesn't report it, rather than showing zeroes that would read
    /// as "none of your library is lossless".
    @ViewBuilder
    private var fidelityView: some View {
        if let fidelity = serverDashboard?.fidelity, fidelity.losslessTracks + fidelity.lossyTracks > 0 {
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Fidelity")
                    .font(.headline)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 12)],
                    spacing: 12
                ) {
                    StatCard(
                        label: "Lossless",
                        value: "\(Int((fidelity.losslessFraction * 100).rounded()))%",
                        detail: "\(fidelity.losslessTracks) tracks"
                    )
                    if fidelity.lossyTracks > 0 {
                        StatCard(
                            label: "Lossy",
                            value: "\(fidelity.lossyTracks)",
                            detail: fidelity.meanLossyBitrate.map {
                                "avg \(Int(($0 / 1000).rounded())) kbps"
                            }
                        )
                    }
                    if fidelity.highResolutionTracks > 0 {
                        StatCard(
                            label: "High resolution",
                            value: "\(fidelity.highResolutionTracks)",
                            detail: "beyond CD"
                        )
                    }
                    if let range = fidelity.dynamicRange, let mean = range.meanCrestDb {
                        StatCard(
                            label: "Dynamic range",
                            value: String(format: "%.1f dB", mean),
                            detail: range.maxCrestDb.map {
                                String(format: "up to %.1f dB", $0)
                            }
                        )
                    }
                }

                Text(
                    "Dynamic range is the average crest factor — the gap between peak and "
                    + "typical level. Higher means the dynamics survived mastering."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                StatCard(label: "Songs", value: "\(library.trackCount)")
                StatCard(label: "Albums", value: "\(library.albumCount)")
                StatCard(label: "Artists", value: "\(library.artistCount)")
                StatCard(
                    label: "Total duration",
                    value: compactDuration(library.totalDuration),
                    detail: formattedBytes(library.fileSizeBytes)
                )
            }

            fidelityView

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
            title: "Most Played Songs",
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

    private func refresh() async {
        let dashboard: StatsDashboard
        if let serverDashboard {
            dashboard = serverDashboard
        } else {
            dashboard = await loadStatsDashboard.execute()
        }
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
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }
}
