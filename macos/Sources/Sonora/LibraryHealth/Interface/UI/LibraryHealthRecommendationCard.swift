import SonoraCommon

import AppKit
import SwiftUI

struct LibraryHealthRecommendationCard: View {
    let recommendation: LibraryHealthRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            copies
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

    private var header: some View {
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
    }

    private var copies: some View {
        VStack(spacing: 0) {
            ForEach(recommendation.copies) { copy in
                copyRow(copy)
                if copy.id != recommendation.copies.last?.id {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    private func copyRow(_ copy: LibraryHealthCopy) -> some View {
        let presentation = LibraryHealthCopyPresentation(copy: copy)
        return HStack(spacing: 10) {
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
                    Text(presentation.fileName)
                        .font(SonoraFont.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(presentation.fileName)

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
                            .background(
                                .green.opacity(0.12),
                                in: Capsule()
                            )
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
                    "\(presentation.formatLabel) · \(presentation.fileSizeLabel) · \(presentation.directoryPath)"
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
                    NSWorkspace.shared.activateFileViewerSelecting([
                        presentation.url
                    ])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel(
                    "Reveal \(presentation.fileName) in Finder"
                )
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
}
