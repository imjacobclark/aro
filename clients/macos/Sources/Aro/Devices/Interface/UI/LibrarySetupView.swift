import AppKit
import AroCommon
import SwiftUI

/// First-run (and "Create New Library…") wizard: a couple of short screens
/// explaining how Aro works, then either creates a new local library (storage
/// mode, sharing, AcoustID, data locations, initial folder) or hands off to
/// `ConnectLibrarySheet`'s pairing flow for an existing one.
struct LibrarySetupView: View {
    @Bindable var registry: LibraryProfileRegistry
    @Bindable var service: AroHubService
    @Bindable var preferences: SyncPreferences
    let activateProfile: (LibraryProfile) -> Void
    let completeRemoteConnection: (
        AroHubInfo,
        URL,
        String,
        OfflineDownloadPolicy
    ) -> Void
    /// Called when this wizard is presented as a sheet (e.g. "Create New
    /// Library…" from an already-configured Settings screen) and the user is
    /// done, one way or another. Left `nil` for the first-run, full-screen
    /// presentation, which instead falls back to `registry.dismissSetup()`.
    var onFinished: (() -> Void)?

    @State private var step: Step = .intro(0)
    @State private var storageChoice: StorageChoice = .stored
    @State private var selectedFolder: URL?
    @State private var sharingEnabled = true
    @State private var acoustidApiKey = ""
    @State private var dataLocation = SyncPreferences.recommendedDataLocation
    @State private var showingConnect = false
    @State private var errorMessage: String?
    @State private var introIconVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                progress
                Group {
                    switch step {
                    case .intro(let page):
                        intro(page)
                    case .choice:
                        choice
                    case .storage:
                        storage
                    case .sharing:
                        sharing
                    case .acoustid:
                        acoustid
                    case .locations:
                        locations
                    case .initialFolder:
                        initialFolder
                    case .complete(let profile):
                        complete(profile)
                    }
                }
                .id(step)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
            }
            .padding(36)
            .frame(maxWidth: 760, minHeight: 520, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: step)
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
            if let label = step.progressLabel {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Intro

    private static let introPages: [(icon: String, title: String, detail: String)] = [
        (
            "point.3.connected.trianglepath.dotted",
            "One library, every device",
            "Aro keeps your music on one device — a small local server called a "
                + "hub — and lets your other Macs, phones, and speakers connect "
                + "to it. Add a song once, and it's everywhere."
        ),
        (
            "waveform.badge.magnifyingglass",
            "It knows your music",
            "Aro identifies tracks and albums automatically, fetches proper "
                + "titles, artwork, and genres, and keeps listening stats and "
                + "smart playlists up to date in the background."
        ),
    ]

    private func intro(_ page: Int) -> some View {
        let content = Self.introPages[page]
        return VStack(alignment: .leading, spacing: 28) {
            Spacer(minLength: 12)
            Image(systemName: content.icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(introIconVisible ? 1 : 0.6)
                .opacity(introIconVisible ? 1 : 0)
                .onAppear {
                    introIconVisible = false
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                        introIconVisible = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 10) {
                Text(content.title)
                    .font(.title.weight(.semibold))
                Text(content.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack {
                pageDots(count: Self.introPages.count, current: page)
                Spacer()
                Button("Skip") { step = .choice }
                    .buttonStyle(.link)
                Button(page == Self.introPages.count - 1 ? "Get Started" : "Continue") {
                    if page == Self.introPages.count - 1 {
                        step = .choice
                    } else {
                        step = .intro(page + 1)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pageDots(count: Int, current: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? AroTheme.violet : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Choice

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
                detail: "Use an Aro library already running elsewhere.",
                button: "Connect to a Library"
            ) {
                showingConnect = true
            }
            Button("Set up later") {
                if let onFinished {
                    onFinished()
                } else {
                    registry.dismissSetup()
                }
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose how Aro stores your music")
                .font(.title2)
            selectionCard(
                selected: storageChoice == .stored,
                title: "Managed by Aro",
                detail: "Recommended. Aro keeps its own bit-identical copy, so the library remains available if an original folder or contributing device goes offline."
            ) {
                storageChoice = .stored
            }
            selectionCard(
                selected: storageChoice == .linked,
                title: "Referenced in place",
                detail: "Aro reads music from its current location without making another copy. Referenced libraries cannot accept uploads and unavailable folders cannot be served."
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
            }

            navigationButtons(primary: "Continue", back: { step = .choice }) {
                step = .sharing
            }
        }
    }

    // MARK: - Sharing

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Use this library on your other devices?")
                .font(.title2)
            Text(
                "Aro always runs a small local server for this library, even if "
                    + "you never turn this on. Enabling it just lets your other "
                    + "devices find and pair with it over your local network."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Toggle(isOn: $sharingEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow my other Aro devices to connect")
                        .font(.headline)
                    Text(
                        "Only devices you approve can connect."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding()
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            navigationButtons(primary: "Continue", back: { step = .storage }) {
                step = .acoustid
            }
        }
    }

    // MARK: - AcoustID

    private var acoustid: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Identify your music automatically?")
                .font(.title2)
            Text(
                "Aro can recognize tracks and albums, fetch proper titles, "
                    + "artwork, and genres in the background. Get a free personal "
                    + "key at acoustid.org — you can always add this later in "
                    + "Settings."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            SecureField("AcoustID API Key (optional)", text: $acoustidApiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
            navigationButtons(primary: "Continue", back: { step = .sharing }) {
                step = .locations
            }
        }
    }

    // MARK: - Locations

    private var locations: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where should Aro keep its own data?")
                .font(.title2)
            Text(
                "This is separate from your music — it's where Aro's local "
                    + "server keeps its library database and, for a managed "
                    + "library, its own verified copy of your files."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            GroupBox {
                HStack {
                    Text(dataLocation)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose…", action: chooseDataLocation)
                }
                .padding(.top, 4)
            }
            navigationButtons(primary: "Continue", back: { step = .acoustid }) {
                step = .initialFolder
            }
        }
    }

    // MARK: - Initial folder

    private var initialFolder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should Aro watch first?")
                .font(.title2)
            Text(
                storageChoice == .stored
                    ? "Aro will copy everything in this folder into your managed "
                        + "library, then keep watching it for changes."
                    : "Aro will index everything in this folder in place, then "
                        + "keep watching it for changes."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            GroupBox {
                HStack {
                    Text(selectedFolder?.lastPathComponent ?? "No folder selected")
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                .padding(.top, 4)
            }
            HStack {
                Button("Back") { step = .locations }
                Spacer()
                Button("Create Library") {
                    guard selectedFolder != nil else {
                        errorMessage = "Choose the folder containing your music."
                        return
                    }
                    createLibrary()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Complete

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
            HStack {
                Spacer()
                Button("Go to My Library") {
                    activateProfile(profile)
                    onFinished?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Shared components

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
            selected ? AroTheme.violet.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func navigationButtons(
        primary: String,
        back: @escaping () -> Void,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Button("Back", action: back)
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

    private func chooseDataLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Location for Aro's Data"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataLocation = url.appendingPathComponent("Aro Library Data").path
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
            if !acoustidApiKey.isEmpty {
                preferences.acoustidApiKey = acoustidApiKey
            }
            if !dataLocation.isEmpty {
                preferences.dataLocation = dataLocation
            }
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

private enum Step: Hashable {
    case intro(Int)
    case choice
    case storage
    case sharing
    case acoustid
    case locations
    case initialFolder
    case complete(LibraryProfile)

    var progressLabel: String? {
        switch self {
        case .intro, .choice: nil
        case .storage: "Step 1 of 5"
        case .sharing: "Step 2 of 5"
        case .acoustid: "Step 3 of 5"
        case .locations: "Step 4 of 5"
        case .initialFolder: "Step 5 of 5"
        case .complete: "Complete"
        }
    }
}
