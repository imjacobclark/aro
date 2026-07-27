import AppKit
import AroCommon
import SwiftUI

struct SyncSettingsView: View {
    @Bindable var service: AroHubService
    @Bindable var preferences: SyncPreferences
    @Bindable var mediaCache: MediaCacheController
    let syncStore: SQLiteSyncOperationStore
    let libraryFiles: any LibraryFileManaging
    let activeProfile: LibraryProfile?
    @Bindable var registry: LibraryProfileRegistry
    let activateProfile: (LibraryProfile) -> Void
    var showsDismissButton = false

    @Environment(\.dismiss) private var dismiss

    @State private var localServers = LocalAroServerMonitor()
    @State private var manualAddress = ""
    @State private var diagnosticStatus: String?
    @State private var showingResetConfirmation = false
    @State private var showingRemovedConfirmation = false
    @State private var importedFolders: [ControlledSourceFolder] = []
    @State private var migrationStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            if showsDismissButton {
                HStack {
                    Text("Library Settings")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            }

            Form {
                if let profile = activeProfile, profile.kind == .remote {
                    remoteLibrarySection(profile)
                } else {
                    localLibrarySections
                }

                if activeProfile?.kind == .remote {
                    Section("Offline Storage") {
                    LabeledContent(
                        "Downloaded files",
                        value: "\(mediaCache.downloadedFileCount)"
                    )
                    LabeledContent(
                        "Space used",
                        value: ByteCountFormatter.string(
                            fromByteCount: mediaCache.usedBytes,
                            countStyle: .file
                        )
                    )
                    LabeledContent(
                        "Protected files",
                        value: "\(mediaCache.protectedFileCount)"
                    )
                    HStack {
                        Button("Delete Removed Downloads…", role: .destructive) {
                            showingRemovedConfirmation = true
                        }
                        Button("Reset Temporary Downloads…", role: .destructive) {
                            showingResetConfirmation = true
                        }
                    }
                    }
                }

                Section("Library Data") {
                    LabeledContent("Database") {
                        Text(libraryFiles.libraryURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(libraryFiles.libraryURL.path)
                    }
                    if activeProfile?.kind != .remote,
                       !preferences.dataLocation.isEmpty {
                        LabeledContent("Sharing data") {
                            Text(preferences.dataLocation)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(preferences.dataLocation)
                        }
                    }
                    if activeProfile?.kind == .local {
                        Button("Move Library Data…", action: moveLibraryData)
                            .disabled(migrationStatus != nil)
                        if let migrationStatus {
                            HStack {
                                ProgressView()
                                Text(migrationStatus)
                            }
                        }
                        Text(
                            "Moves the database, Aro-managed music, downloads, "
                                + "and Background Service data. Original locations "
                                + "are retained as recoverable backups."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if activeProfile?.kind != .remote {
                    Section("Imported Folders") {
                        if importedFolders.isEmpty {
                            Text(
                                service.isEnabled
                                    ? "No folders have been imported."
                                    : "Start sharing to manage imported folders."
                            )
                            .foregroundStyle(.secondary)
                        }
                        ForEach(
                            0 ..< importedFolders.count,
                            id: \.self
                        ) { (index: Int) in
                            importedFolderRow(importedFolders[index])
                        }
                        HStack {
                            Button("Add Folder…", action: addImportedFolder)
                                .disabled(!service.isEnabled)
                            Button("Refresh", action: refreshImportedFolders)
                                .disabled(!service.isEnabled)
                        }
                        Text(
                            "Stopping a watch keeps every imported song in this Aro."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if activeProfile?.kind != .remote,
                   let warning = localServers.networkWarning {
                    Section("Network") {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if let diagnosticStatus {
                    Section("Result") {
                        Text(diagnosticStatus)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding()
        .frame(width: 640, height: 620)
        .onAppear {
            manualAddress = preferences.manualAddress
            refresh()
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog(
            "Delete downloads removed from the source library?",
            isPresented: $showingRemovedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Removed Downloads", role: .destructive) {
                mediaCache.deleteRemovedDownloads()
                diagnosticStatus = mediaCache.statusMessage
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only downloaded copies are deleted. The source library is not changed, and files can be downloaded again if they return."
            )
        }
        .confirmationDialog(
            "Reset temporary offline downloads?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Downloads", role: .destructive) {
                mediaCache.clear()
                diagnosticStatus = mediaCache.statusMessage
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Temporary downloads will be removed. Favourites, selected albums, queued music, and the playing song remain protected."
            )
        }
    }

    @ViewBuilder
    private var localLibrarySections: some View {
        Section("This Library") {
            if let profile = activeProfile {
                LabeledContent("Library", value: profile.name)
                LabeledContent(
                    "Storage",
                    value: profile.managedMusicPath == nil
                        ? "Linked files"
                        : "Stored by Aro"
                )
            }
            if let server = bundledServer {
                LabeledContent("Sharing", value: "Available")
                LabeledContent(
                    "Network address",
                    value: friendlyListener(server.listener)
                )
                LabeledContent(
                    "Listening interfaces",
                    value: server.listener.hasPrefix("*")
                        ? "All local interfaces"
                        : server.listener
                )
                LabeledContent("Process ID", value: "\(server.pid)")
                if let sequence = server.sequence {
                    LabeledContent("Library sequence", value: "\(sequence)")
                }
                if let tracks = server.trackCount {
                    LabeledContent("Indexed songs", value: "\(tracks)")
                }
                if let files = server.blobCount {
                    LabeledContent("Stored files", value: "\(files)")
                }
            } else {
                LabeledContent(
                    "Sharing",
                    value: service.isEnabled ? "Starting…" : "Off"
                )
                Text(
                    "Music remains available locally while sharing is off."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Restart Sharing Service", action: restartService)
                    .disabled(!service.isEnabled)
                Button("Copy Diagnostic Information", action: copyDiagnostics)
                Button("Open Logs", action: openLogs)
            }
        }

        Section("Manual Connection") {
            TextField(
                "Address",
                text: $manualAddress,
                prompt: Text("https://aro-example.local:4848")
            )
            HStack {
                Button("Test Connection", action: testConnection)
                    .disabled(URL(string: manualAddress)?.scheme != "https")
                Text(
                    "Automatic discovery is the recommended way to connect."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func remoteLibrarySection(
        _ profile: LibraryProfile
    ) -> some View {
        Section("Connected Library") {
            LabeledContent("Library", value: profile.name)
            if let baseURL = profile.baseURL {
                LabeledContent("Address") {
                    Text(displayAddress(baseURL))
                        .textSelection(.enabled)
                }
            }
            LabeledContent(
                "Download behaviour",
                value: offlinePolicyName(profile.offlinePolicy)
            )
            Text(
                "This Mac uses an Aro library hosted elsewhere. It is not serving its own library."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack {
                Button("Test Connected Library") {
                    testConnectedLibrary(profile)
                }
                Button("Copy Diagnostic Information", action: copyDiagnostics)
            }
        }
    }

    private var bundledServer: LocalAroServer? {
        localServers.servers.first { $0.kind == .bundledHelper }
    }

    private func refresh() {
        localServers.refresh()
        mediaCache.refreshSummary()
        refreshImportedFolders()
    }

    private var controlClient: HubControlClient? {
        guard !preferences.dataLocation.isEmpty else { return nil }
        return HubControlClient(
            socketURL: URL(fileURLWithPath: preferences.dataLocation)
                .appendingPathComponent("control.sock")
        )
    }

    private func refreshImportedFolders() {
        guard service.isEnabled, let controlClient else {
            importedFolders = []
            return
        }
        Task {
            do {
                importedFolders = try await controlClient.folders()
            } catch {
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    private func addImportedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Import"
        panel.prompt = "Import Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let path = panel.url?.path,
              let controlClient else { return }
        Task {
            do {
                _ = try await controlClient.importFolder(
                    path: path,
                    mode: preferences.importMode
                )
                importedFolders = try await controlClient.folders()
            } catch {
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    private func scanFolder(_ id: UUID) {
        guard let controlClient else { return }
        Task {
            do {
                try await controlClient.scanFolder(id)
                importedFolders = try await controlClient.folders()
            } catch {
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    private func stopWatching(_ id: UUID) {
        guard let controlClient else { return }
        Task {
            do {
                try await controlClient.removeFolder(id)
                importedFolders = try await controlClient.folders()
            } catch {
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func importedFolderRow(
        _ folder: ControlledSourceFolder
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(folder.name).font(.headline)
                Spacer()
                Text(folder.watching ? "Watching" : "Detached")
                    .foregroundStyle(
                        folder.available ? Color.secondary : Color.orange
                    )
            }
            Text(folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text("\(folder.songCount) songs · \(folder.missingCount) unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = folder.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if folder.watching {
                HStack {
                    Button("Scan Now") {
                        scanFolder(folder.id)
                    }
                    Button("Stop Watching", role: .destructive) {
                        stopWatching(folder.id)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func moveLibraryData() {
        guard let profile = activeProfile, profile.kind == .local else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a New Location for Library Data"
        panel.prompt = "Move Library Data"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let wasEnabled = service.isEnabled
        migrationStatus = "Preparing and verifying the new copy…"
        if wasEnabled {
            service.setEnabled(false)
        }
        Task {
            do {
                if wasEnabled {
                    try await Task.sleep(for: .seconds(1))
                }
                let result = try await LibraryDataMigrator().migrate(
                    profile: profile,
                    libraryFiles: libraryFiles,
                    serverDataPath: preferences.dataLocation,
                    into: parent
                )
                registry.update(result.profile)
                preferences.dataLocation = result.serverDataPath
                activateProfile(result.profile)
                if wasEnabled {
                    service.setEnabled(true)
                    await service.ensureCompatibleHelper(
                        dataLocation: result.serverDataPath
                    )
                }
                migrationStatus = nil
                diagnosticStatus =
                    "Library Data moved to \(result.root.path). "
                    + "The previous locations were retained as backups."
            } catch {
                if wasEnabled {
                    service.setEnabled(true)
                }
                migrationStatus = nil
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    private func restartService() {
        diagnosticStatus = "Restarting the library service…"
        Task {
            await service.restartForUpgrade()
            localServers.refresh()
            diagnosticStatus = service.errorMessage
                ?? "The library service restarted successfully."
        }
    }

    private func testConnection() {
        guard let url = URL(string: manualAddress) else { return }
        diagnosticStatus = "Testing connection…"
        Task {
            do {
                let info = try await AroSyncClient(
                    discoveryBaseURL: url
                ).compatibleHubInfo()
                preferences.manualAddress = url.absoluteString
                diagnosticStatus = "Reached \(info.displayName). Secure pairing is \(info.pairingAvailable ? "available" : "not currently open")."
            } catch {
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    private func testConnectedLibrary(_ profile: LibraryProfile) {
        guard let baseURL = profile.baseURL,
              let membership = syncStore.membership(baseURL: baseURL) else {
            diagnosticStatus =
                "The saved connection information is incomplete. Connect to the library again."
            return
        }
        diagnosticStatus = "Testing \(profile.name)…"
        Task {
            do {
                let info = try await AroSyncClient(
                    baseURL: baseURL,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                ).compatibleHubInfo()
                diagnosticStatus =
                    "\(info.displayName) is online and its saved certificate matches."
            } catch {
                diagnosticStatus = error.localizedDescription
            }
        }
    }

    private func copyDiagnostics() {
        let server = bundledServer
        let text: String
        if let profile = activeProfile, profile.kind == .remote {
            text = """
            Aro Connected Library Diagnostics
            Library: \(profile.name)
            Address: \(profile.baseURL.map(displayAddress) ?? "unknown")
            Download behaviour: \(offlinePolicyName(profile.offlinePolicy))
            Database: \(libraryFiles.libraryURL.path)
            Offline usage: \(mediaCache.usedBytes) bytes
            """
        } else {
            text = """
            Aro Library Diagnostics
            Library: \(activeProfile?.name ?? "unconfigured")
            Sharing: \(server == nil ? "off" : "available")
            Listener: \(server?.listener ?? "none")
            Process: \(server.map { String($0.pid) } ?? "none")
            Songs: \(server?.trackCount.map(String.init) ?? "unknown")
            Files: \(server?.blobCount.map(String.init) ?? "unknown")
            Sequence: \(server?.sequence.map(String.init) ?? "unknown")
            Database: \(libraryFiles.libraryURL.path)
            """
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        diagnosticStatus = "Diagnostic information copied."
    }

    private func openLogs() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Aro", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(logs)
    }

    private func friendlyListener(_ listener: String) -> String {
        listener.replacingOccurrences(of: "*:", with: "aro.local:")
    }

    private func displayAddress(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    private func offlinePolicyName(
        _ policy: OfflineDownloadPolicy
    ) -> String {
        switch policy {
        case .stream:
            "Stream as needed"
        case .favourites:
            "Keep favourites offline"
        case .selectedAlbums:
            "Keep selected albums offline"
        case .fullLibrary:
            "Keep the full library offline"
        }
    }
}
