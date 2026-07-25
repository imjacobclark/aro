import AppKit
import SonoraCommon
import SwiftUI

struct SyncSettingsView: View {
    @Bindable var service: SonoraHubService
    @Bindable var preferences: SyncPreferences
    @Bindable var mediaCache: MediaCacheController
    let syncStore: SQLiteSyncOperationStore
    let libraryFiles: any LibraryFileManaging
    @State private var requestedHosting = false
    @State private var browser = SonoraHubBrowser()
    @State private var pairingCode = ""
    @State private var pairingFingerprint = ""
    @State private var pairingStatus: String?
    @State private var hostingPairingWindow: HubPairingWindow?
    @State private var pairedDevices: [ControlledHubDevice] = []
    @State private var firstJoinPreview: FirstJoinPreview?
    @State private var conflictResolutions: [String: SyncConflictChoice] = [:]
    @State private var showingFirstJoin = false
    @State private var isCommittingJoin = false
    @State private var isSyncing = false

    var body: some View {
        Form {
            Section("Host This Library") {
                Toggle("Enable Sonora Hub", isOn: Binding(
                    get: { service.isEnabled || requestedHosting },
                    set: {
                        requestedHosting = $0
                        service.setEnabled($0)
                        requestedHosting = service.isEnabled
                    }
                ))
                .disabled(preferences.dataLocation.isEmpty)
                .help(
                    preferences.dataLocation.isEmpty
                        ? "Choose a server-data location first."
                        : ""
                )
                LabeledContent("Helper Status", value: service.statusLabel)
                Button("Open Pairing Window") {
                    openHostingPairing()
                }
                .disabled(!service.isEnabled)
                if let hostingPairingWindow {
                    LabeledContent("Pairing Code") {
                        Text(hostingPairingWindow.code)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("TLS fingerprint: \(hostingPairingWindow.fingerprint)")
                        .font(SonoraFont.footnote)
                        .textSelection(.enabled)
                }

                LabeledContent("Server Data") {
                    HStack {
                        Text(
                            preferences.dataLocation.isEmpty
                                ? "Required before import"
                                : preferences.dataLocation
                        )
                        .lineLimit(1)
                        Button("Choose…", action: chooseDataLocation)
                    }
                }

                Picker("Import Mode", selection: $preferences.importMode) {
                    Text("Managed (recommended)").tag(HubImportMode.managed)
                    Text("Referenced").tag(HubImportMode.referenced)
                }

                if let capacityDescription {
                    Text(capacityDescription)
                        .font(SonoraFont.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Connect to a Hub") {
                LabeledContent("Discovered Hubs") {
                    if browser.hubs.isEmpty {
                        Text("Searching on the local network…")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Discovered Hubs", selection: $preferences.manualAddress) {
                            Text("Choose a hub").tag("")
                            ForEach(browser.hubs) { hub in
                                Text(hub.name)
                                    .tag("https://\(hub.host):4848")
                            }
                        }
                        .labelsHidden()
                    }
                }
                TextField(
                    "Manual hostname or IP",
                    text: $preferences.manualAddress,
                    prompt: Text("https://sonora.local:4848")
                )
                TextField("Six-digit pairing code", text: $pairingCode)
                SecureField(
                    "Hub TLS fingerprint from QR or hub",
                    text: $pairingFingerprint
                )
                HStack {
                    Button("Pair…", action: pair)
                        .disabled(
                            preferences.manualAddress.isEmpty
                                || pairingCode.isEmpty
                                || pairingFingerprint.count != 64
                        )
                    Button("Review First Join…", action: reviewFirstJoin)
                        .disabled(
                            preferences.manualAddress.isEmpty
                                || pairingFingerprint.count != 64
                        )
                    Button("Sync Now", action: synchronizeNow)
                        .disabled(
                            isSyncing
                                || preferences.manualAddress.isEmpty
                                || pairingFingerprint.count != 64
                        )
                }
                if let pairingStatus {
                    Text(pairingStatus)
                        .font(SonoraFont.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Media Replica") {
                Picker("Replica Mode", selection: $preferences.replicaMode) {
                    Text("On Demand").tag(SyncReplicaMode.onDemand)
                    Text("Full Mirror").tag(SyncReplicaMode.fullMirror)
                }
                if preferences.replicaMode == .onDemand {
                    LabeledContent("Cache Limit") {
                        Stepper(
                            value: cacheLimitGiB,
                            in: 1 ... 2_048,
                            step: 5
                        ) {
                            Text("\(cacheLimitGiB.wrappedValue) GB")
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Button("Clear Cache") {
                            mediaCache.clear()
                        }
                        Text("Pinned, queued, and playing files are protected.")
                            .font(SonoraFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let status = mediaCache.statusMessage {
                        Text(status)
                            .font(SonoraFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Full Mirror downloads every blob to the selected mirror location and never evicts automatically.")
                        .font(SonoraFont.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Paired Devices") {
                if pairedDevices.isEmpty {
                    Text("No paired devices.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairedDevices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                revoke(device)
                            }
                        }
                    }
                }
                HStack {
                    Button("Refresh", action: refreshDevices)
                        .disabled(!service.isEnabled)
                    Button("Purge Tombstoned Media…", role: .destructive) {}
                        .disabled(!service.isEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 620)
        .alert(
            "Unable to Change Hosting",
            isPresented: Binding(
                get: { service.errorMessage != nil },
                set: { if !$0 { service.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.errorMessage ?? "Unknown helper error.")
        }
        .onAppear {
            requestedHosting = service.isEnabled
            browser.start()
        }
        .onDisappear {
            browser.stop()
        }
        .sheet(isPresented: $showingFirstJoin) {
            if let firstJoinPreview {
                firstJoinSheet(firstJoinPreview)
            } else {
                ProgressView("Comparing libraries…")
                    .padding(40)
            }
        }
    }

    private var cacheLimitGiB: Binding<Int> {
        Binding(
            get: {
                Int(preferences.cacheLimitBytes / (1_024 * 1_024 * 1_024))
            },
            set: {
                preferences.cacheLimitBytes = Int64($0) * 1_024 * 1_024 * 1_024
            }
        )
    }

    private var capacityDescription: String? {
        guard !preferences.dataLocation.isEmpty else { return nil }
        let url = URL(fileURLWithPath: preferences.dataLocation)
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return "Available: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
    }

    private func chooseDataLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Sonora Server Data Location"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.dataLocation = url.path
    }

    private func pair() {
        guard let url = URL(string: preferences.manualAddress) else {
            pairingStatus = "Enter a valid HTTPS hub address."
            return
        }
        pairingStatus = "Submitting pairing request…"
        Task {
            do {
                let defaults = UserDefaults.standard
                let deviceID: UUID
                if let stored = defaults.string(
                    forKey: "library.deviceID"
                ).flatMap(UUID.init(uuidString:)) {
                    deviceID = stored
                } else {
                    deviceID = UUID()
                    defaults.set(
                        deviceID.uuidString,
                        forKey: "library.deviceID"
                    )
                }
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: pairingFingerprint
                )
                let requestID = try await client.startPairing(
                    deviceID: deviceID,
                    deviceName: Host.current().localizedName ?? "Mac",
                    code: pairingCode,
                    fingerprint: pairingFingerprint
                )
                pairingStatus = "Request \(requestID) is waiting for approval on the hub."
                for _ in 0 ..< 150 {
                    try await Task.sleep(for: .seconds(2))
                    if let credential = try await client.pollPairing(
                        requestID: requestID,
                        deviceID: deviceID
                    ) {
                        let info = try await client.hubInfo()
                        try KeychainHubCredentialStore().save(
                            credential,
                            hubID: info.hubID
                        )
                        syncStore.upsertMembership(
                            hub: info,
                            baseURL: url,
                            tlsFingerprint: pairingFingerprint,
                            replicaMode: preferences.replicaMode
                        )
                        pairingStatus = "Paired with \(info.displayName)."
                        return
                    }
                }
                pairingStatus = "Pairing expired. Open a new code on the hub."
            } catch {
                pairingStatus = error.localizedDescription
            }
        }
    }

    private var controlClient: HubControlClient? {
        guard !preferences.dataLocation.isEmpty else { return nil }
        return HubControlClient(
            socketURL: URL(
                fileURLWithPath: preferences.dataLocation
            ).appendingPathComponent("control.sock")
        )
    }

    private func openHostingPairing() {
        guard let controlClient else { return }
        Task {
            do {
                hostingPairingWindow = try await controlClient.openPairing()
                refreshDevices()
            } catch {
                service.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshDevices() {
        guard let controlClient else { return }
        Task {
            do {
                pairedDevices = try await controlClient.devices()
            } catch {
                service.errorMessage = error.localizedDescription
            }
        }
    }

    private func revoke(_ device: ControlledHubDevice) {
        guard let controlClient else { return }
        Task {
            do {
                try await controlClient.revoke(deviceID: device.deviceID)
                pairedDevices = try await controlClient.devices()
            } catch {
                service.errorMessage = error.localizedDescription
            }
        }
    }

    private func reviewFirstJoin() {
        guard let url = URL(string: preferences.manualAddress) else {
            pairingStatus = "Enter a valid HTTPS hub address."
            return
        }
        firstJoinPreview = nil
        conflictResolutions = [:]
        showingFirstJoin = true
        Task {
            do {
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: pairingFingerprint
                )
                let info = try await client.hubInfo()
                let deviceID = libraryDeviceID
                guard let credential = try KeychainHubCredentialStore().load(
                    hubID: info.hubID,
                    deviceID: deviceID
                ) else {
                    throw FirstJoinUIError.notPaired
                }
                syncStore.upsertMembership(
                    hub: info,
                    baseURL: url,
                    tlsFingerprint: pairingFingerprint,
                    replicaMode: preferences.replicaMode
                )
                let coordinator = FirstJoinCoordinator(
                    client: client,
                    credential: credential,
                    libraryFiles: libraryFiles
                )
                firstJoinPreview = try await coordinator.preview(
                    manifest: syncStore.manifest(hubID: info.hubID)
                )
            } catch {
                showingFirstJoin = false
                pairingStatus = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func firstJoinSheet(_ preview: FirstJoinPreview) -> some View {
        let requiredMedia = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: preview.requiredBytes),
            countStyle: .file
        )
        VStack(alignment: .leading, spacing: 16) {
            Text("Review First Join")
                .font(.title)
            Text(
                "\(preview.deduplicatedTracks) identical, "
                    + "\(preview.localOnlyTracks) local-only, "
                    + "\(preview.hubOnlyTracks) hub-only"
            )
            Text("Media required: \(requiredMedia)")
            .foregroundStyle(.secondary)

            if preview.conflicts.isEmpty {
                ContentUnavailableView(
                    "No Mutable-State Conflicts",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Unique records from both libraries will be imported."
                    )
                )
            } else {
                List(preview.conflicts, id: \.resolutionKey) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(conflict.field)
                            .font(SonoraFont.headline)
                        Picker(
                            "Use",
                            selection: conflictBinding(conflict)
                        ) {
                            Text("Choose…").tag(
                                Optional<SyncConflictChoice>.none
                            )
                            Text(
                                "This Mac: \(display(conflict.local.value))"
                            )
                            .tag(Optional(SyncConflictChoice.local))
                            Text(
                                "Hub: \(display(conflict.hub.value))"
                            )
                            .tag(Optional(SyncConflictChoice.hub))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingFirstJoin = false
                }
                Button("Back Up and Merge") {
                    commitFirstJoin(preview)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isCommittingJoin
                        || conflictResolutions.count != preview.conflicts.count
                )
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
    }

    private func conflictBinding(
        _ conflict: SyncFieldConflict
    ) -> Binding<SyncConflictChoice?> {
        Binding(
            get: { conflictResolutions[conflict.resolutionKey] },
            set: { conflictResolutions[conflict.resolutionKey] = $0 }
        )
    }

    private func commitFirstJoin(_ preview: FirstJoinPreview) {
        guard let url = URL(string: preferences.manualAddress) else { return }
        isCommittingJoin = true
        Task {
            defer { isCommittingJoin = false }
            do {
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: pairingFingerprint
                )
                let info = try await client.hubInfo()
                guard let credential = try KeychainHubCredentialStore().load(
                    hubID: info.hubID,
                    deviceID: libraryDeviceID
                ) else {
                    throw FirstJoinUIError.notPaired
                }
                let result = try await FirstJoinCoordinator(
                    client: client,
                    credential: credential,
                    libraryFiles: libraryFiles
                ).commit(
                    preview: preview,
                    resolutions: conflictResolutions
                )
                pairingStatus = "Merge completed. Backup: \(result.backupURL.path)"
                showingFirstJoin = false
                synchronizeNow()
            } catch {
                pairingStatus = error.localizedDescription
            }
        }
    }

    private func synchronizeNow() {
        guard let url = URL(string: preferences.manualAddress) else {
            pairingStatus = "Enter a valid HTTPS hub address."
            return
        }
        isSyncing = true
        pairingStatus = "Synchronizing…"
        Task {
            defer { isSyncing = false }
            do {
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: pairingFingerprint
                )
                let info = try await client.hubInfo()
                guard let credential = try KeychainHubCredentialStore().load(
                    hubID: info.hubID,
                    deviceID: libraryDeviceID
                ) else {
                    throw FirstJoinUIError.notPaired
                }
                let result = try await HubSyncCoordinator(
                    hubID: info.hubID,
                    client: client,
                    credential: credential,
                    operations: syncStore
                ).synchronize()
                pairingStatus = "Sync complete: \(result.uploadedOperations) uploaded, \(result.appliedOperations) applied."
            } catch {
                pairingStatus = error.localizedDescription
            }
        }
    }

    private var libraryDeviceID: UUID {
        if let value = UserDefaults.standard.string(
            forKey: "library.deviceID"
        ).flatMap(UUID.init(uuidString:)) {
            return value
        }
        let value = UUID()
        UserDefaults.standard.set(
            value.uuidString,
            forKey: "library.deviceID"
        )
        return value
    }

    private func display(_ value: JSONValue) -> String {
        switch value {
        case .null:
            "None"
        case .bool(let value):
            value ? "Yes" : "No"
        case .number(let value):
            value.formatted()
        case .string(let value):
            value
        case .array, .object:
            "Structured value"
        }
    }
}

private enum FirstJoinUIError: LocalizedError {
    case notPaired

    var errorDescription: String? {
        "Pair with this hub before reviewing the first join."
    }
}
