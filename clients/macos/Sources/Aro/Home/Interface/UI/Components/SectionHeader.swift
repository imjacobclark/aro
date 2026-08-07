import AroCommon
import SwiftUI

/// A section title plus optional subtitle, used above every Home section — replaces
/// the ad hoc header `VStack`s that used to be duplicated per section.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AroFont.textStyle(.title3, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(AroFont.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
