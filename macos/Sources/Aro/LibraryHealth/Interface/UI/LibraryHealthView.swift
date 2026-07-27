import AroCommon

import SwiftUI

struct LibraryHealthView: View {
    @State private var report = LibraryHealthReport()

    let reviewLibraryHealth: ReviewLibraryHealth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summary

                if report.recommendationCount == 0 {
                    emptyState
                } else {
                    recommendations
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .task {
            while !Task.isCancelled {
                report = reviewLibraryHealth.execute()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library Health")
                    .font(AroFont.largeTitle)
                    .lineLimit(1)
                Text(
                    "\(report.recommendationCount) recommendations · review only"
                )
                .font(AroFont.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 12)
            AppSettingsButton()
        }
    }

    private var summary: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 132), spacing: 12)
            ],
            spacing: 12
        ) {
            LibraryHealthSummaryCard(
                label: "Exact copies",
                value: "\(report.exactDuplicates.count)",
                symbol: "doc.on.doc"
            )
            LibraryHealthSummaryCard(
                label: "Likely matches",
                value: "\(report.alternateEncodings.count)",
                symbol: "waveform.path.ecg"
            )
            LibraryHealthSummaryCard(
                label: "Exact savings",
                value: report.exactReclaimableBytes == 0
                    ? "0 KB"
                    : ByteCountFormatter.string(
                        fromByteCount: report.exactReclaimableBytes,
                        countStyle: .file
                    ),
                symbol: "externaldrive"
            )
            LibraryHealthSummaryCard(
                label: "Missing",
                value: "\(report.missingFiles.count)",
                symbol: "questionmark.folder"
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Library Looks Clean", systemImage: "checkmark.seal")
        } description: {
            Text(
                "No duplicate, alternate-format, moved, or missing files were found."
            )
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var recommendations: some View {
        Group {
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
                    "Aro found a current copy and retained its former location.",
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
                        .font(AroFont.headline)
                    Text(subtitle)
                        .font(AroFont.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(recommendations) { recommendation in
                        LibraryHealthRecommendationCard(
                            recommendation: recommendation
                        )
                    }
                }
            }
        }
    }
}
