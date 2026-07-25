import SonoraCommon

import SwiftUI

struct LibraryHealthSummaryCard: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(
                        SonoraFont.textStyle(
                            .caption,
                            weight: .semibold
                        )
                    )
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
        .frame(
            maxWidth: .infinity,
            minHeight: 76,
            alignment: .leading
        )
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
