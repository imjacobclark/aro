import AroCommon

import SwiftUI

struct FolderRow: View {
    let folder: WatchedFolder
    let scanState: FolderScanState

    var body: some View {
        HStack {
            Label(folder.displayName, systemImage: "folder")
                .lineLimit(1)

            Spacer()

            switch scanState {
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Syncing")
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Sync needs attention")
            case .idle:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("In sync")
            }
        }
    }
}
