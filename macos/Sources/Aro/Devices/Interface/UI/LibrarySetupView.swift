import AppKit
import AroCommon
import SwiftUI

struct LibrarySetupView: View {
    @Bindable var registry: LibraryProfileRegistry
    let activateProfile: (LibraryProfile) -> Void
    let completeRemoteConnection: (
        AroHubInfo,
        URL,
        String,
        OfflineDownloadPolicy
    ) -> Void

    @State private var step: Step = .choice
    @State private var storageChoice: StorageChoice = .stored
    @State private var selectedFolder: URL?
    @State private var sharingEnabled = true
    @State private var showingConnect = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            progress
            switch step {
            case .choice:
                choice
            case .storage:
                storage
            case .sharing:
                sharing
            case .complete(let profile):
                complete(profile)
            }
        }
        .padding(36)
        .frame(maxWidth: 760, maxHeight: 620)
        .sheet(isPresented: $showingConnect) {
            ConnectLibrarySheet(
                completeConnection: completeRemoteConnection
            )
        }
        .alert(
            "Unable to Create Library",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var progress: some View {
        HStack {
            Text("Set Up Aro")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            if step != .choice {
                Text(step.progressLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What would you like to do?")
                .font(.title2)
            setupCard(
                icon: "music.note.house",
                title: "Start a new music library",
                detail: "Keep your music on this Mac and make it available to your other Aro devices.",
                button: "Create a Library"
            ) {
                step = .storage
            }
            setupCard(
                icon: "rectangle.connected.to.line.below",
                title: "Connect to an existing library",
                detail: "Use a Aro library already running elsewhere.",
                button: "Connect to a Library"
            ) {
                showingConnect = true
            }
            Button("Set up later") {
                registry.dismissSetup()
            }
            .buttonStyle(.link)
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose how Aro stores your music")
                .font(.title2)
            selectionCard(
                selected: storageChoice == .stored,
                title: "Stored by Aro",
                detail: "Recommended. Aro keeps its own bit-identical copy, so the library remains available if an original folder or contributing device goes offline."
            ) {
                storageChoice = .stored
            }
            selectionCard(
                selected: storageChoice == .linked,
                title: "Linked files",
                detail: "Aro reads music from its current location without making another copy. Linked libraries cannot accept uploads and unavailable folders cannot be served."
            ) {
                storageChoice = .linked
            }

            if storageChoice == .stored {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Aro Music Library")
                                .font(.headline)
                            Text("Stored in your Music folder")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(managedLibraryURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            } else {
                GroupBox {
                    HStack {
                        Text(selectedFolder?.lastPathComponent ?? "No folder selected")
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                    .padding(.top, 4)
                }
            }

            Spacer()
            navigationButtons(primary: "Continue") {
                guard storageChoice == .stored || selectedFolder != nil else {
                    errorMessage = "Choose the folder containing your music."
                    return
                }
                step = .sharing
            }
        }
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Use this library on your other devices?")
                .font(.title2)
            Toggle(isOn: $sharingEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow my other Aro devices to connect")
                        .font(.headline)
                    Text(
                        "Aro makes this library available on your local network. Only devices you approve can connect."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding()
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
            navigationButtons(
                primary: sharingEnabled ? "Enable Sharing" : "Create Library"
            ) {
                createLibrary()
            }
        }
    }

    private func complete(_ profile: LibraryProfile) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ContentUnavailableView {
                Label("Your library is ready", systemImage: "checkmark.circle.fill")
            } description: {
                Text(
                    sharingEnabled
                        ? "\(profile.name) is stored on this Mac and is available to approved devices."
                        : "\(profile.name) is stored on this Mac."
                )
            }
            Spacer()
            HStack {
                Spacer()
                Button("Go to My Library") {
                    activateProfile(profile)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func setupCard(
        icon: String,
        title: String,
        detail: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
        }
        .padding(20)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func selectionCard(
        selected: Bool,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
        .background(
            selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func navigationButtons(
        primary: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Button("Back") {
                step = step == .sharing ? .storage : .choice
            }
            Spacer()
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Music Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        selectedFolder = panel.url
    }

    private func createLibrary() {
        let managedPath = storageChoice == .stored
            ? managedLibraryURL.path
            : nil
        do {
            if let managedPath {
                try FileManager.default.createDirectory(
                    atPath: managedPath,
                    withIntermediateDirectories: true
                )
            }
            let deviceName = Host.current().localizedName ?? "This Mac"
            let profile = registry.createLocal(
                name: "\(deviceName)’s Music Library",
                managedMusicPath: managedPath,
                referencedMusicPaths: selectedFolder.map { [$0.path] } ?? [],
                sharingEnabled: sharingEnabled
            )
            step = .complete(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var managedLibraryURL: URL {
        FileManager.default.urls(
            for: .musicDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Aro Music Library", isDirectory: true)
    }
}

private enum StorageChoice {
    case stored
    case linked
}

private enum Step: Equatable {
    case choice
    case storage
    case sharing
    case complete(LibraryProfile)

    var progressLabel: String {
        switch self {
        case .choice: ""
        case .storage: "Step 1 of 2"
        case .sharing: "Step 2 of 2"
        case .complete: "Complete"
        }
    }
}
