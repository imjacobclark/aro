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

    @State private var localServers = LocalAroServerMonitor()
    @State private var manualAddress = ""
    @State private var diagnosticStatus: String?
    @State private var importedFolders: [ControlledSourceFolder] = []
    @State private var migrationStatus: String?
    @State private var isAdvancedExpanded = false

    var body: some View {
        embeddedSettings
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
    }

    @ViewBuilder
    private var embeddedSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if activeProfile?.kind != .remote {
                SettingsCard(title: "Library Sources") {
                    importedFoldersContent
                    Divider()
                    libraryDataContent
                }
            }

            SettingsCard {
                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let profile = activeProfile,
                           profile.kind == .remote {
                            remoteLibraryContent(profile)
                        } else {
                            localLibraryContent
                            Divider()
                            Text("Manual Connection")
                                .font(.headline)
                            manualConnectionContent
                        }

                        if activeProfile?.kind == .remote {
                            Divider()
                            libraryDataContent
                        }

                        if activeProfile?.kind != .remote,
                           let warning = localServers.networkWarning {
                            Divider()
                            networkWarningContent(warning)
                        }

                        if let errorMessage = localServers.errorMessage {
                            Divider()
                            networkWarningContent(errorMessage)
                        }

                        if let errorMessage = preferences.errorMessage {
                            Divider()
                            networkWarningContent(errorMessage)
                        }

                        if let diagnosticStatus {
                            Divider()
                            diagnosticResultContent(diagnosticStatus)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("Advanced")
                        .font(.title3.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var localLibraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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
    }

    private var manualConnectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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

    private func remoteLibraryContent(
        _ profile: LibraryProfile
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)
            if let baseURL = profile.baseURL {
                LabeledContent("Address") {
                    Text(displayAddress(baseURL))
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Test Connected Library") {
                    testConnectedLibrary(profile)
                }
                Button("Copy Diagnostic Information", action: copyDiagnostics)
            }
        }
    }

    @ViewBuilder
    private var libraryDataContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(
                activeProfile?.kind == .remote
                    ? "Local cache"
                    : "Library location"
            ) {
                Text(libraryFiles.libraryURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(libraryFiles.libraryURL.path)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    libraryFiles.libraryURL
                ])
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
    }

    private var importedFoldersContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if importedFolders.isEmpty {
                Text(
                    service.isEnabled
                        ? "No folders have been imported."
                        : "Start sharing to manage imported folders."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(0 ..< importedFolders.count, id: \.self) { index in
                importedFolderRow(importedFolders[index])
            }
            HStack {
                Button("Add Folder…", action: addImportedFolder)
                    .disabled(!service.isEnabled)
                Button("Refresh", action: refreshImportedFolders)
                    .disabled(!service.isEnabled)
            }
            Text("Stopping a watch keeps every imported song in this Aro.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func networkWarningContent(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
    }

    private func diagnosticResultContent(_ status: String) -> some View {
        Text(status)
            .textSelection(.enabled)
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
        case .streamOnly:
            "Stream only"
        case .stream:
            "Keep recently played"
        case .favourites, .selectedAlbums:
            "Keep favourite albums or songs"
        case .fullLibrary:
            "Keep the full library offline"
        }
    }
}
