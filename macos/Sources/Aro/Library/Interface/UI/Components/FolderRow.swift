import AroCommon

import SwiftUI

struct FolderRow: View {
    let folder: WatchedFolder
    let scanState: FolderScanState
    var isHostLibraryFolder: Bool = false

    var body: some View {
        HStack {
            Label(
                folder.displayName,
                systemImage: folder.url.isFileURL ? "folder" : "network"
            )
            .lineLimit(1)

            if isHostLibraryFolder {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("This Mac's shared library folder")
                    .help("This Mac's shared library folder — served to your other devices")
            }

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
