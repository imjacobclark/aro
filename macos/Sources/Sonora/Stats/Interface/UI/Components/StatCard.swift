import SonoraCommon

import SwiftUI

struct StatCard: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label)
                .font(SonoraFont.textStyle(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(SonoraFont.fixed(27, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
            Text(detail ?? " ")
                .font(SonoraFont.caption)
                .foregroundStyle(.secondary)
                .opacity(detail == nil ? 0 : 1)
                .accessibilityHidden(detail == nil)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(16)
        .statsSurface()
    }
}
