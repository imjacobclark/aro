import AroCommon
import SwiftUI

struct NavigationSidebar: View {
    @Binding var selection: Destination?
    let folders: [WatchedFolder]
    let scanStates: [UUID: FolderScanState]
    let canAddSync: Bool
    let addSyncHelp: String
    let canRemoveSyncs: Bool
    let addSync: () -> Void
    let removeSync: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                navigationRow("Home", systemImage: "house.fill")
                    .tag(Destination.home)
                navigationRow("Songs", systemImage: "music.note.list")
                    .tag(Destination.songs)
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
                        scanState: scanStates[folder.id] ?? .idle
                    )
                    .font(AroFont.fixed(14))
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
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 20, height: 20)
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
        .tint(AroTheme.violet)
    }

    private func navigationRow(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label {
            Text(title)
                .font(AroFont.fixed(14, weight: .semibold))
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 18)
        }
        .padding(.vertical, 3)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AroFont.fixed(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
