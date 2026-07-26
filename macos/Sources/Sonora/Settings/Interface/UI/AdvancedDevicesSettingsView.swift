import AppKit
import SonoraCommon
import SwiftUI

struct SyncSettingsView: View {
    @Bindable var service: SonoraHubService
    @Bindable var preferences: SyncPreferences
    @Bindable var mediaCache: MediaCacheController
    let syncStore: SQLiteSyncOperationStore
    let libraryFiles: any LibraryFileManaging
    let activeProfile: LibraryProfile?

    @State private var localServers = LocalSonoraServerMonitor()
    @State private var manualAddress = ""
    @State private var diagnosticStatus: String?
    @State private var showingResetConfirmation = false
    @State private var showingRemovedConfirmation = false

    var body: some View {
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
                }
                if activeProfile?.kind != .remote,
                   !preferences.dataLocation.isEmpty {
                    LabeledContent("Sharing data") {
                        Text(preferences.dataLocation)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
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
                "Temporary downloads will be removed. Favourites, selected albums, queued music, and the playing track remain protected."
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
                        : "Stored by Sonora"
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
                    LabeledContent("Indexed tracks", value: "\(tracks)")
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
                prompt: Text("https://sonora-example.local:4848")
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
                "This Mac uses a Sonora library hosted elsewhere. It is not serving its own library."
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

    private var bundledServer: LocalSonoraServer? {
        localServers.servers.first { $0.kind == .bundledHelper }
    }

    private func refresh() {
        localServers.refresh()
        mediaCache.refreshSummary()
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
                let info = try await SonoraSyncClient(
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
                let info = try await SonoraSyncClient(
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
            Sonora Connected Library Diagnostics
            Library: \(profile.name)
            Address: \(profile.baseURL.map(displayAddress) ?? "unknown")
            Download behaviour: \(offlinePolicyName(profile.offlinePolicy))
            Database: \(libraryFiles.libraryURL.path)
            Offline usage: \(mediaCache.usedBytes) bytes
            """
        } else {
            text = """
            Sonora Library Diagnostics
            Library: \(activeProfile?.name ?? "unconfigured")
            Sharing: \(server == nil ? "off" : "available")
            Listener: \(server?.listener ?? "none")
            Process: \(server.map { String($0.pid) } ?? "none")
            Tracks: \(server?.trackCount.map(String.init) ?? "unknown")
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
            .appendingPathComponent("Library/Logs/Sonora", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(logs)
    }

    private func friendlyListener(_ listener: String) -> String {
        listener.replacingOccurrences(of: "*:", with: "sonora.local:")
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
