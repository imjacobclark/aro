import AroCommon

import SwiftUI

struct RankedStatsList: View {
    let title: String
    let values: [RankedListeningStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AroFont.headline)
            if values.isEmpty {
                EmptyStatsText(
                    text: "Nothing played yet. Start listening to populate this list."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.element.id) {
                        index, value in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(value.title)
                                    .font(
                                        AroFont.textStyle(
                                            .body,
                                            weight: .semibold
                                        )
                                    )
                                    .lineLimit(1)
                                    .help(value.title)
                                Text(value.subtitle)
                                    .font(AroFont.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(value.subtitle)
                            }
                            Spacer()
                            Text("\(value.playCount)")
                                .font(AroFont.headline)
                                .monospacedDigit()
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
