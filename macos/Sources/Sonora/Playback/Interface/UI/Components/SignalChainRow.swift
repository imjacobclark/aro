import SonoraCommon

import SwiftUI

struct SignalChainStep: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

struct SignalChainRow: View {
    let step: SignalChainStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(
                    .tint.opacity(0.1),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(SonoraFont.textStyle(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(step.detail)
                    .font(SonoraFont.subheadline)
                    .lineLimit(1)
                    .help(step.detail)
            }

            Spacer(minLength: 0)
        }
    }
}
