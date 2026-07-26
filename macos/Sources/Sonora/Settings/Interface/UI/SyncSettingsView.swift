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
    @State private var localServers = LocalSonoraServerMonitor()
    @State private var hostedImportStatus: String?
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
            Section("Active Sonora Servers") {
                if localServers.servers.isEmpty {
                    Text(
                        service.isEnabled
                            ? "The Sonora Background Service is enabled but is not listening."
                            : "No Sonora servers are currently listening on this Mac."
                    )
                        .foregroundStyle(.secondary)
                    if service.isEnabled {
                        Button("Restart Background Service") {
                            recoverBundledHelper()
                        }
                    }
                } else {
                    ForEach(localServers.servers) { server in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .font(SonoraFont.headline)
                                    Text(server.kind.label)
                                        .font(SonoraFont.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Stop", role: .destructive) {
                                    stopLocalServer(server)
                                }
                            }
                            LabeledContent("Listener", value: server.listener)
                            if let dataPath = server.dataPath {
                                LabeledContent("Library Data") {
                                    Text(dataPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(dataPath)
                                }
                            }
                            HStack(spacing: 18) {
                                if let trackCount = server.trackCount {
                                    Text("\(trackCount) songs")
                                }
                                if let blobCount = server.blobCount {
                                    Text("\(blobCount) blobs")
                                }
                                if let sequence = server.sequence {
                                    Text("sequence \(sequence)")
                                }
                                Text("PID \(server.pid)")
                            }
                            .font(SonoraFont.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                HStack {
                    Button("Refresh") {
                        localServers.refresh()
                    }
                    if let error = localServers.errorMessage {
                        Text(error)
                            .font(SonoraFont.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Host This Sonora") {
                LabeledContent("Library Data") {
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
                            + "prepare this Sonora and start its Background Service."
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

                Toggle("Host This Sonora", isOn: Binding(
                    get: { service.isEnabled || requestedHosting },
                    set: { enabled in
                        setHostingEnabled(enabled)
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
                LabeledContent(
                    "Background Status",
                    value: bundledHelperIsActive
                        ? "Running"
                        : service.statusLabel
                )
                if let hostedImportStatus {
                    Text(hostedImportStatus)
                        .font(SonoraFont.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Open Pairing Window") {
                    openHostingPairing()
                }
                .disabled(!bundledHelperIsActive)
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

            Section("Connect to a Sonora") {
                LabeledContent("Available Sonoras") {
                    HStack {
                        if browser.hubs.isEmpty {
                            Text(
                                browser.isSearching
                                    ? "Checking the local network…"
                                    : "No active Sonoras found"
                            )
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(
                                "Available Sonoras",
                                selection: $preferences.manualAddress
                            ) {
                                Text("Choose a Sonora").tag("")
                                ForEach(browser.hubs) { hub in
                                    Text(hub.name)
                                        .tag(hub.address)
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
                        .disabled(!bundledHelperIsActive)
                    Button("Purge Tombstoned Media…", role: .destructive) {}
                        .disabled(!bundledHelperIsActive)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 640, height: 720)
        .alert(
            "Unable to Change Hosting",
            isPresented: Binding(
                get: { service.errorMessage != nil },
                set: { if !$0 { service.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.errorMessage ?? "Unknown Background Service error.")
        }
        .onAppear {
            requestedHosting = service.isEnabled
            localServers.refresh()
            refreshDiscovery()
            if service.isEnabled {
                Task {
                    await service.ensureCompatibleHelper(
                        dataLocation: preferences.dataLocation
                    )
                    await publishWatchedFolders()
                }
            }
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
        .task {
            while !Task.isCancelled {
                localServers.refresh()
                try? await Task.sleep(for: .seconds(2))
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

    private var bundledHelperIsActive: Bool {
        localServers.servers.contains {
            $0.kind == .bundledHelper
        }
    }

    private func refreshDiscovery() {
        if !syncStore.hasMemberships {
            preferences.manualAddress = ""
            pairingCode = ""
            pairingStatus = nil
        }
        browser.restart()
    }

    private func stopLocalServer(_ server: LocalSonoraServer) {
        switch server.kind {
        case .bundledHelper:
            requestedHosting = false
            service.setEnabled(false)
            if service.errorMessage != nil {
                localServers.stopBundledService(server)
                if localServers.errorMessage == nil {
                    service.errorMessage = nil
                }
            }
        case .standalone:
            localServers.stopStandalone(server)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            localServers.refresh()
        }
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
        panel.title = "Choose Sonora Library Data Location"
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
                await publishWatchedFolders()
            }
        }
    }

    private func useRecommendedDataLocation() {
        preferences.dataLocation = SyncPreferences.recommendedDataLocation
        if service.isEnabled {
            Task {
                await service.restartForUpgrade()
                await publishWatchedFolders()
            }
        }
    }

    private func setHostingEnabled(_ enabled: Bool) {
        if !enabled,
           let running = localServers.servers.first(where: {
               $0.kind == .bundledHelper
           }) {
            stopLocalServer(running)
            return
        }
        if enabled,
           !service.isEnabled,
           let stale = localServers.servers.first(where: {
               $0.kind == .bundledHelper
           }) {
            localServers.stopBundledService(stale)
            guard localServers.errorMessage == nil else { return }
        }
        requestedHosting = enabled
        service.setEnabled(enabled)
        requestedHosting = service.isEnabled
        guard enabled, service.errorMessage == nil else {
            if !enabled {
                hostedImportStatus = nil
            }
            return
        }
        Task {
            await service.ensureCompatibleHelper(
                dataLocation: preferences.dataLocation
            )
            await publishWatchedFolders()
        }
    }

    private func recoverBundledHelper() {
        Task {
            hostedImportStatus = "Restarting the Background Service…"
            await service.restartForUpgrade()
            await publishWatchedFolders()
        }
    }

    private func publishWatchedFolders() async {
        guard service.errorMessage == nil,
              let controlClient else {
            return
        }
        let paths = syncStore.activeWatchedFolderPaths
        guard !paths.isEmpty else {
            hostedImportStatus = "No active watched folders to publish."
            localServers.refresh()
            return
        }
        hostedImportStatus = "Publishing \(paths.count) watched folder"
            + (paths.count == 1 ? "…" : "s…")
        do {
            var imported = 0
            for path in paths {
                imported += try await controlClient.importFolder(
                    path: path,
                    mode: preferences.importMode
                )
            }
            hostedImportStatus = imported == 0
                ? "Hosted library is up to date."
                : "Published \(imported) songs to this Sonora."
            localServers.refresh()
        } catch {
            service.errorMessage = "Unable to publish the watched library: "
                + error.localizedDescription
        }
    }

    private func pair() {
        guard let url = URL(string: preferences.manualAddress) else {
            pairingStatus = "Enter a valid HTTPS Sonora address."
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
                pairingStatus = "Request \(pairing.requestID) is waiting for approval on the hosting Sonora."
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
                        pairingStatus = "The hosting Sonora rejected this pairing request."
                        return
                    case .expired:
                        pairingStatus = "Pairing expired. Open a new code on the hosting Sonora."
                        return
                    }
                }
                pairingStatus = "Pairing expired. Open a new code on the hosting Sonora."
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
            pairingStatus = "Enter a valid HTTPS Sonora address."
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
                "\(preview.deduplicatedTracks) identical songs, "
                    + "\(preview.localOnlyTracks) local-only songs, "
                    + "\(preview.hubOnlyTracks) hosting-Sonora-only songs"
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
                                "Hosting Sonora: \(display(conflict.hub.value))"
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
            pairingStatus = "Enter a valid HTTPS Sonora address."
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
            "Pair with this Sonora before reviewing the first join."
        case .hubIdentityChanged:
            "The Sonora identity at this address has changed. Pair again before continuing."
        }
    }
}
