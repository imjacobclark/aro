import AroCommon
import SwiftUI

struct NavigationSidebar: View {
    @Binding var selection: Destination?
    let folders: [WatchedFolder]
    let scanStates: [UUID: FolderScanState]
    let canAddSync: Bool
    let addSyncHelp: String
    let canRemoveSyncs: Bool
    /// Connection health of the active *remote* library, or `nil` when this Mac is
    /// hosting its own — see `RemoteSyncHealth`.
    var remoteSyncHealth: RemoteSyncHealth?
    let addSync: () -> Void
    let removeSync: (UUID) -> Void
    /// Icon boxes grow with the labels beside them. Pinned, they would leave every icon
    /// shrinking away from its own text as the reader turns the system size up.
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var leadingIconWidth: CGFloat = 18

    var body: some View {
        List(selection: $selection) {
            Section {
                navigationRow("Home", systemImage: "house.fill")
                    .tag(Destination.home)
                navigationRow("Songs", systemImage: "music.note.list")
                    .tag(Destination.songs)
                navigationRow("Favourites", systemImage: "heart.fill")
                    .tag(Destination.favourites)
                navigationRow("Artists", systemImage: "music.mic")
                    .tag(Destination.artists)
                navigationRow("Albums", systemImage: "square.stack")
                    .tag(Destination.albums)
                navigationRow("Stats", systemImage: "chart.bar.xaxis")
                    .tag(Destination.stats)
                navigationRow(
                    "Library Health",
                    systemImage: "checkmark.shield"
                )
                .tag(Destination.libraryHealth)
                navigationRow(
                    "Metadata",
                    systemImage: "waveform.badge.magnifyingglass"
                )
                .tag(Destination.metadata)
            } header: {
                sectionHeading("Library")
            }

            Section {
                ForEach(folders) { folder in
                    FolderRow(
                        folder: folder,
                        scanState: scanStates[folder.id] ?? .idle,
                        remoteSyncHealth: remoteSyncHealth
                    )
                    .font(AroFont.scaled(14, relativeTo: .headline))
                    .tag(Destination.folder(folder.id))
                    .contextMenu {
                        if canRemoveSyncs {
                            Button("Remove Folder", role: .destructive) {
                                removeSync(folder.id)
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    sectionHeading("Syncs")
                    Spacer()
                    Button(action: addSync) {
                        Image(systemName: "plus")
                            .font(AroFont.scaled(12, relativeTo: .subheadline, weight: .semibold))
                            .frame(width: iconSize, height: iconSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAddSync)
                    .help(addSyncHelp)
                    .accessibilityLabel("Add Sync")
                }
            }

            Section {
                navigationRow("Settings", systemImage: "gearshape")
                    .tag(Destination.settings)
            } header: {
                sectionHeading("Manage")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AroTheme.sidebarSurface)
        // Sidebar selection is drawn by AppKit and ignores this tint entirely; it
        // follows the bundle's `NSAccentColorName`/`AccentColor` asset instead (see
        // scripts/build-app.sh). This still covers the controls inside the sidebar.
        .tint(AroTheme.violet)
    }

    private func navigationRow(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label {
            Text(title)
                .font(AroFont.scaled(14, relativeTo: .headline, weight: .semibold))
        } icon: {
            Image(systemName: systemImage)
                .font(AroFont.scaled(15, relativeTo: .title3))
                .frame(width: leadingIconWidth)
        }
        .padding(.vertical, 3)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AroFont.scaled(10, relativeTo: .caption2, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
