import SonoraCommon

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
                    .accessibilityLabel("Scanning")
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Folder warning")
            case .idle:
                EmptyView()
            }
        }
    }
}
