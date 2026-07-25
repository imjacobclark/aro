import SonoraCommon

import SwiftUI

struct EmptyStatsText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SonoraFont.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

extension View {
    func statsSurface() -> some View {
        background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
        }
    }
}
