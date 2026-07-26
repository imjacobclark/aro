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
    @State private var pairingStatus: String?
    @State private var hostingPairingWindow: HubPairingWindow?
    @State private var pendingPairingRequests: [ControlledPairingRequest] = []
    @State private var pairedDevices: [ControlledHubDevice] = []
    @State private var firstJoinPreview: FirstJoinPreview?
    @State private var conflictResolutions: [String: SyncConflictChoice] = [:]
    @State private var showingFirstJoin = false
    @State private var isCommittingJoin = false
    @State private var isSyncing = false

    var body: some View {
        Form {
            Section("Host This Library") {
                LabeledContent("Server Data") {
                    HStack {
                        Text(
                            preferences.dataLocation.isEmpty
                                ? "Choose a location to enable hosting"
                                : preferences.dataLocation
                        )
                        .lineLimit(1)
                        Button("Choose…", action: chooseDataLocation)
                    }
                }

                if preferences.dataLocation.isEmpty {
                    Text(
                        "Sonora needs a server-data location before it can "
                            + "create the hub configuration and start the helper."
                    )
                    .font(SonoraFont.footnote)
                    .foregroundStyle(.secondary)
                    Button(
                        "Use Recommended Location",
                        action: useRecommendedDataLocation
                    )
                } else if !SyncPreferences.isSupportedHelperLocation(
                    preferences.dataLocation
                ) {
                    Text(SyncPreferences.protectedLocationMessage)
                        .font(SonoraFont.footnote)
                        .foregroundStyle(.orange)
                    Button(
                        "Use Recommended Location",
                        action: useRecommendedDataLocation
                    )
                }

                Toggle("Enable Sonora Hub", isOn: Binding(
                    get: { service.isEnabled || requestedHosting },
                    set: {
                        requestedHosting = $0
                        service.setEnabled($0)
                        requestedHosting = service.isEnabled
                    }
                ))
                .disabled(
                    (
                        preferences.dataLocation.isEmpty
                            || !SyncPreferences.isSupportedHelperLocation(
                                preferences.dataLocation
                            )
                    ) && !service.isEnabled
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
                    if pendingPairingRequests.isEmpty {
                        Text("Waiting for a device to submit this code…")
                            .font(SonoraFont.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pendingPairingRequests) { request in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(request.deviceName)
                                    Text(request.deviceID.uuidString)
                                        .font(SonoraFont.footnote)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("Reject", role: .destructive) {
                                    approvePairing(request, approve: false)
                                }
                                Button("Approve") {
                                    approvePairing(request, approve: true)
                                }
                            }
                        }
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
                    HStack {
                        if browser.hubs.isEmpty {
                            Text("Searching on the local network…")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(
                                "Discovered Hubs",
                                selection: $preferences.manualAddress
                            ) {
                                Text("Choose a hub").tag("")
                                ForEach(browser.hubs) { hub in
                                    Text(hub.name)
                                        .tag("https://\(hub.host):4848")
                                }
                            }
                            .labelsHidden()
                        }
                        Button {
                            refreshDiscovery()
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .labelsHidden()
                    }
                }
                if let discoveryError = browser.errorMessage {
                    Text("Local discovery failed: \(discoveryError)")
                        .font(SonoraFont.footnote)
                        .foregroundStyle(.orange)
                }
                TextField(
                    "Manual hostname or IP",
                    text: $preferences.manualAddress,
                    prompt: Text("https://sonora.local:4848")
                )
                TextField("Six-digit pairing code", text: $pairingCode)
                HStack {
                    Button("Pair…", action: pair)
                        .disabled(
                            preferences.manualAddress.isEmpty
                                || pairingCode.count != 6
                        )
                    Button("Review First Join…", action: reviewFirstJoin)
                        .disabled(preferences.manualAddress.isEmpty)
                    Button("Sync Now", action: synchronizeNow)
                        .disabled(
                            isSyncing
                                || preferences.manualAddress.isEmpty
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
            refreshDiscovery()
        }
        .onDisappear {
            browser.stop()
        }
        .task(id: hostingPairingWindow?.code) {
            guard hostingPairingWindow != nil else { return }
            while !Task.isCancelled {
                await refreshPendingPairingRequests()
                try? await Task.sleep(for: .seconds(1))
            }
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

    private func refreshDiscovery() {
        if !syncStore.hasMemberships {
            preferences.manualAddress = ""
            pairingCode = ""
            pairingStatus = nil
        }
        browser.restart()
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
        guard SyncPreferences.isSupportedHelperLocation(url.path) else {
            service.errorMessage = SyncPreferences.protectedLocationMessage
            return
        }
        preferences.dataLocation = url.path
        if service.isEnabled {
            Task {
                await service.restartForUpgrade()
            }
        }
    }

    private func useRecommendedDataLocation() {
        preferences.dataLocation = SyncPreferences.recommendedDataLocation
        if service.isEnabled {
            Task {
                await service.restartForUpgrade()
            }
        }
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
                let pairingClient = SonoraSyncClient(pairingBaseURL: url)
                let pairing = try await pairingClient.startPairing(
                    deviceID: deviceID,
                    deviceName: Host.current().localizedName ?? "Mac",
                    code: pairingCode
                )
                pairingStatus = "Request \(pairing.requestID) is waiting for approval on the hub."
                for _ in 0 ..< 150 {
                    try await Task.sleep(for: .seconds(2))
                    let result = try await pairingClient.pollPairing(
                        pairing: pairing
                    )
                    switch result {
                    case .pending:
                        continue
                    case .approved(let completed):
                        let client = SonoraSyncClient(
                            baseURL: url,
                            pinnedTLSFingerprint: completed.tlsFingerprint
                        )
                        let info = try await client.hubInfo()
                        try KeychainHubCredentialStore().save(
                            completed.credential,
                            hubID: info.hubID
                        )
                        syncStore.upsertMembership(
                            hub: info,
                            baseURL: url,
                            tlsFingerprint: completed.tlsFingerprint,
                            replicaMode: preferences.replicaMode
                        )
                        pairingStatus = "Paired with \(info.displayName)."
                        return
                    case .rejected:
                        pairingStatus = "The hub rejected this pairing request."
                        return
                    case .expired:
                        pairingStatus = "Pairing expired. Open a new code on the hub."
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
                pendingPairingRequests = []
                refreshDevices()
            } catch {
                service.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshPendingPairingRequests() async {
        guard let controlClient else { return }
        do {
            pendingPairingRequests = try await controlClient
                .pendingPairingRequests()
        } catch {
            service.errorMessage = error.localizedDescription
        }
    }

    private func approvePairing(
        _ request: ControlledPairingRequest,
        approve: Bool
    ) {
        guard let controlClient else { return }
        Task {
            do {
                try await controlClient.approvePairing(
                    requestID: request.requestID,
                    approve: approve
                )
                await refreshPendingPairingRequests()
                pairedDevices = try await controlClient.devices()
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
                guard let membership = syncStore.membership(baseURL: url) else {
                    throw FirstJoinUIError.notPaired
                }
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                )
                let info = try await client.hubInfo()
                guard info.hubID == membership.hubID else {
                    throw FirstJoinUIError.hubIdentityChanged
                }
                let deviceID = libraryDeviceID
                guard let credential = try KeychainHubCredentialStore().load(
                    hubID: membership.hubID,
                    deviceID: deviceID
                ) else {
                    throw FirstJoinUIError.notPaired
                }
                syncStore.upsertMembership(
                    hub: info,
                    baseURL: url,
                    tlsFingerprint: membership.tlsFingerprint,
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
                guard let membership = syncStore.membership(baseURL: url) else {
                    throw FirstJoinUIError.notPaired
                }
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                )
                let info = try await client.hubInfo()
                guard info.hubID == membership.hubID else {
                    throw FirstJoinUIError.hubIdentityChanged
                }
                guard let credential = try KeychainHubCredentialStore().load(
                    hubID: membership.hubID,
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
                guard let membership = syncStore.membership(baseURL: url) else {
                    throw FirstJoinUIError.notPaired
                }
                let client = SonoraSyncClient(
                    baseURL: url,
                    pinnedTLSFingerprint: membership.tlsFingerprint
                )
                let info = try await client.hubInfo()
                guard info.hubID == membership.hubID else {
                    throw FirstJoinUIError.hubIdentityChanged
                }
                guard let credential = try KeychainHubCredentialStore().load(
                    hubID: membership.hubID,
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
    case hubIdentityChanged

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "Pair with this hub before reviewing the first join."
        case .hubIdentityChanged:
            "The hub identity at this address has changed. Pair again before continuing."
        }
    }
}
