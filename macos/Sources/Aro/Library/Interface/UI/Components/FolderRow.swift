import AroCommon

import SwiftUI

/// Connection health for a *remote* library, distinct from `FolderScanState` (which
/// only describes local scanning). A remote sync being "idle" says nothing about
/// whether the hub is actually reachable, so on its own it would show a reassuring
/// green tick against a server that has been unreachable for hours.
enum RemoteSyncHealth {
    /// Last attempt succeeded — in sync and the hub is answering.
    case online
    /// Can't reach the hub, but nothing local is waiting to go out, so nothing is
    /// at risk: everything we have is already on the server.
    case offline
    /// Either the last attempt errored, or we're unreachable *and* holding local
    /// changes that haven't reached the hub yet. That's the case worth alarming
    /// about, since those changes exist nowhere else.
    case failing
}

struct FolderRow: View {
    let folder: WatchedFolder
    let scanState: FolderScanState
    var isHostLibraryFolder: Bool = false
    /// Supplied only for remote libraries; `nil` for local folders, which fall back
    /// to the plain in-sync tick.
    var remoteSyncHealth: RemoteSyncHealth?

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
                switch remoteSyncHealth {
                case .offline:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In sync, library offline")
                        .help("In sync — the library is currently unreachable")
                case .failing:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Sync failing")
                        .help("Changes on this Mac haven't reached the library yet")
                case .online, .none:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("In sync")
                }
            }
        }
    }
}
