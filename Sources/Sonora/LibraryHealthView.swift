import AppKit
import SwiftUI

struct LibraryHealthView: View {
    @State private var report = LibraryHealthReport()

    private let database = LibraryDatabase.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library Health")
                            .font(SonoraFont.largeTitle)
                            .lineLimit(1)
                        Text(
                            "\(report.recommendationCount) recommendations · review only"
                        )
                        .font(SonoraFont.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    AppSettingsButton()
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 132), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    HealthSummaryCard(
                        label: "Exact copies",
                        value: "\(report.exactDuplicates.count)",
                        symbol: "doc.on.doc"
                    )
                    HealthSummaryCard(
                        label: "Likely matches",
                        value: "\(report.alternateEncodings.count)",
                        symbol: "waveform.path.ecg"
                    )
                    HealthSummaryCard(
                        label: "Exact savings",
                        value: formattedBytes(report.exactReclaimableBytes),
                        symbol: "externaldrive"
                    )
                    HealthSummaryCard(
                        label: "Missing",
                        value: "\(report.missingFiles.count)",
                        symbol: "questionmark.folder"
                    )
                }

                if report.recommendationCount == 0 {
                    ContentUnavailableView {
                        Label("Library Looks Clean", systemImage: "checkmark.seal")
                    } description: {
                        Text(
                            "No duplicate, alternate-format, moved, or missing files were found."
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    recommendationSection(
                        title: "Exact Duplicates",
                        subtitle:
                            "Byte-for-byte matches. These are the safest copies to review.",
                        recommendations: report.exactDuplicates
                    )
                    recommendationSection(
                        title: "Likely Same Recording",
                        subtitle:
                            "Different encodings with matching artist, title, and duration. Confirm these manually.",
                        recommendations: report.alternateEncodings
                    )
                    recommendationSection(
                        title: "Moved Files",
                        subtitle:
                            "Sonora found a current copy and retained its former location.",
                        recommendations: report.movedFiles
                    )
                    recommendationSection(
                        title: "Missing Files",
                        subtitle:
                            "These remain in your library history but have no available local copy.",
                        recommendations: report.missingFiles
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .task {
            while !Task.isCancelled {
                report = database.libraryHealthReport()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func recommendationSection(
        title: String,
        subtitle: String,
        recommendations: [LibraryHealthRecommendation]
    ) -> some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SonoraFont.headline)
                    Text(subtitle)
                        .font(SonoraFont.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(recommendations) { recommendation in
                        RecommendationCard(recommendation: recommendation)
                    }
                }
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct HealthSummaryCard: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(SonoraFont.textStyle(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
            }
            Text(value)
                .font(SonoraFont.fixed(25, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(14)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
        }
    }
}

private struct RecommendationCard: View {
    let recommendation: LibraryHealthRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: recommendationSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(recommendationColor)
                    .frame(width: 36, height: 36)
                    .background(
                        recommendationColor.opacity(0.12),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.title)
                        .font(
                            SonoraFont.textStyle(
                                .body,
                                weight: .semibold
                            )
                        )
                        .lineLimit(1)
                        .help(recommendation.title)
                    Text(recommendation.artist)
                        .font(SonoraFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(recommendation.artist)
                    Text(recommendation.reason)
                        .font(SonoraFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .layoutPriority(1)

                Spacer()

                if recommendation.potentialSavingsBytes > 0 {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount:
                                recommendation.potentialSavingsBytes,
                            countStyle: .file
                        )
                    )
                    .font(
                        SonoraFont.textStyle(
                            .caption,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.green)
                }
            }
            .padding(14)

            Divider()

            VStack(spacing: 0) {
                ForEach(recommendation.copies) { copy in
                    copyRow(copy)
                    if copy.id != recommendation.copies.last?.id {
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.7)
        }
    }

    private func copyRow(_ copy: LibraryHealthCopy) -> some View {
        HStack(spacing: 10) {
            Image(
                systemName: copy.isAvailable
                    ? "doc.fill"
                    : "doc.badge.ellipsis"
            )
            .foregroundStyle(
                copy.isAvailable ? Color.secondary : Color.orange
            )
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(copy.url.lastPathComponent)
                        .font(SonoraFont.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(copy.url.lastPathComponent)

                    if copy.id == recommendation.preferredCopyID {
                        Text("Keep")
                            .font(
                                SonoraFont.textStyle(
                                    .caption2,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                    } else if !copy.isAvailable {
                        Text("Missing")
                            .font(
                                SonoraFont.textStyle(
                                    .caption2,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(.orange)
                    }
                }

                Text(
                    "\(copy.formatLabel) · \(formattedBytes(copy.fileSizeBytes)) · \(copy.url.deletingLastPathComponent().path)"
                )
                .font(SonoraFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(copy.path)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if copy.isAvailable {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([copy.url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(copy.url.lastPathComponent) in Finder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var recommendationSymbol: String {
        switch recommendation.kind {
        case .exactDuplicate:
            "doc.on.doc.fill"
        case .alternateEncoding:
            "waveform.path.ecg"
        case .moved:
            "arrow.triangle.swap"
        case .missing:
            "questionmark.folder.fill"
        }
    }

    private var recommendationColor: Color {
        switch recommendation.kind {
        case .exactDuplicate:
            .green
        case .alternateEncoding:
            SonoraTheme.violet
        case .moved:
            SonoraTheme.coral
        case .missing:
            SonoraTheme.amber
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
