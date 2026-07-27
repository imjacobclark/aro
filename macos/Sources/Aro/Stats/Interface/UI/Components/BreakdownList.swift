import AroCommon

import SwiftUI

struct BreakdownList: View {
    let title: String
    let values: [LibraryBreakdownStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AroFont.headline)
            if values.isEmpty {
                EmptyStatsText(text: "No metadata available yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(values) { value in
                        HStack {
                            Text(value.name)
                                .font(
                                    AroFont.textStyle(
                                        .body,
                                        weight: .semibold
                                    )
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(value.name)
                            Spacer()
                            Text("\(value.trackCount) songs")
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: value.fileSizeBytes,
                                    countStyle: .file
                                )
                            )
                            .font(AroFont.caption)
                            .frame(width: 90, alignment: .trailing)
                        }
                        .padding(12)
                        if value.id != values.last?.id {
                            Divider()
                        }
                    }
                }
                .statsSurface()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
