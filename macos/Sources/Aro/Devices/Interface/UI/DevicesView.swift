import AroCommon
import SwiftUI

struct LibrarySettingsView: View {
    @Bindable var library: LibraryStore
    @Bindable var registry: LibraryProfileRegistry
    @Bindable var service: AroHubService
    @Bindable var preferences: SyncPreferences
    @Bindable var mediaCache: MediaCacheController
    let syncStore: SQLiteSyncOperationStore
    let libraryFiles: any LibraryFileManaging
    let activateProfile: (LibraryProfile) -> Void
    let forgetProfile: (LibraryProfile) -> Void
    let completeRemoteConnection: (
        AroHubInfo,
        URL,
        String,
        OfflineDownloadPolicy
    ) -> Void

    @State private var localServers = LocalAroServerMonitor()
    @State private var pairedDevices: [ControlledHubDevice] = []
    @State private var sourceFolders: [ControlledSourceFolder] = []
    @State private var pairingSession: PairingSession?
    @State private var addDeviceError: String?
    @State private var showingConnect = false
    @State private var showingCreateLibrary = false
    @State private var connectionInitialAddress = ""
    @State private var showingOfflineSettings = false
    @State private var deviceToRemove: ControlledHubDevice?
    @State private var profileToForget: LibraryProfile?
    @State private var statusMessage: String?
    @State private var isSyncing = false
    @State private var exportSession: LibraryExportSession?
    @State private var exportStartedService = false
    @State private var settingsSection: SettingsSection = .overview
    @State private var remoteTopology: RemoteTopologySnapshot?
    @State private var remoteTopologyError: String?
    @State private var topologyOnline = false

    var body: some View {
        Group {
            if !registry.isConfigured && !registry.setupDismissed {
                LibrarySetupView(
                    registry: registry,
                    service: service,
                    preferences: preferences,
                    activateProfile: activateProfile,
                    completeRemoteConnection: completeRemoteConnection
                )
            } else {
                dashboard
            }
        }
        .sheet(item: $pairingSession) { session in
            AddDeviceSheet(
                client: session.client,
                hubID: session.hubID,
                port: session.port,
                onDevicesChanged: { pairedDevices = $0 }
            )
        }
        .sheet(isPresented: $showingConnect) {
            ConnectLibrarySheet(
                completeConnection: completeRemoteConnection,
                willPauseSharing: registry.activeProfile?.kind == .local
                    && (registry.activeProfile?.sharingEnabled ?? false),
                initialAddress: connectionInitialAddress,
                excludedHubID: connectionInitialAddress.isEmpty
                    ? registry.activeProfile?.hubID
                    : nil
            )
        }
        .sheet(isPresented: $showingCreateLibrary) {
            LibrarySetupView(
                registry: registry,
                service: service,
                preferences: preferences,
                activateProfile: activateProfile,
                completeRemoteConnection: completeRemoteConnection,
                onFinished: { showingCreateLibrary = false }
            )
            .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: $showingOfflineSettings) {
            if let profile = registry.activeProfile {
                OfflineMusicSettingsSheet(
                    profile: profile,
                    albums: Array(
                        Set(library.allSongs.compactMap(\.album))
                    ).sorted(),
                    registry: registry,
                    mediaCache: mediaCache
                )
            }
        }
        .sheet(item: $exportSession, onDismiss: finishExportSession) { session in
            ExportLibrarySheet(session: session)
        }
        .onChange(of: mediaCache.errorMessage) {
            // OfflineMusicSettingsSheet fires MediaCacheController.apply(...)
            // as a Task and dismisses immediately, so a failure can only be
            // known after the sheet has already closed — surface it here,
            // in the status line the user returns to.
            if let error = mediaCache.errorMessage {
                statusMessage = error
            }
        }
        .confirmationDialog(
            "Remove \(deviceToRemove?.name ?? "this device")?",
            isPresented: Binding(
                get: { deviceToRemove != nil },
                set: { if !$0 { deviceToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                if let deviceToRemove {
                    revoke(deviceToRemove)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "It will lose access to this library. Downloaded music will be removed the next time Aro opens on that device."
            )
        }
        .confirmationDialog(
            "Forget \(profileToForget?.name ?? "this library")?",
            isPresented: Binding(
                get: { profileToForget != nil },
                set: { if !$0 { profileToForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget Library", role: .destructive) {
                if let profileToForget {
                    forgetProfile(profileToForget)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Aro will remove its local copy and downloaded music for this library on this Mac only. The library itself, and any other device connected to it, is unaffected."
            )
        }
        .alert(
            "Unable to Add a Device",
            isPresented: Binding(
                get: { addDeviceError != nil },
                set: { if !$0 { addDeviceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                addDeviceError
                    ?? "Aro could not contact the library service."
            )
        }
        .task {
            await refresh()
        }
        .task {
            while !Task.isCancelled {
                localServers.refresh()
                await refreshDevices()
                await refreshSources()
                let interval: Duration = settingsSection == .topology ? .seconds(5) : .seconds(30)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Picker("Settings section", selection: $settingsSection) {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                if settingsSection == .topology, let profile = registry.activeProfile {
                    topologyPage(profile)
                } else if let profile = registry.activeProfile {
                    libraryCard(profile)
                    if profile.kind == .local {
                        connectedDevicesCard(profile)
                    }
                    offlineMusicCard(profile)
                    advancedSettings
                } else {
                    unconfiguredState
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func topologyPage(_ profile: LibraryProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library Topology")
                .font(.title2.weight(.semibold))
            Text("A live visual map of where your music lives and the devices connected to it.")
                .foregroundStyle(.secondary)
            LibraryTopologyView(
                profile: profile,
                songCount: topologySongCount(profile),
                sources: sourceFolders,
                devices: pairedDevices,
                currentDeviceID: libraryDeviceID,
                activeTransfers: remoteTopology?.activeTransfers ?? 0,
                livePlayback: remoteTopology?.livePlayback ?? [],
                localHubOnline: topologyOnline
            )
            if let remoteTopologyError {
                Label(remoteTopologyError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var header: some View {
        headerTitle
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Your libraries, connected devices, storage, and service controls"
            )
                .foregroundStyle(.secondary)
        }
    }

    private func libraryCard(_ profile: LibraryProfile) -> some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: profile.kind == .local ? "desktopcomputer" : "music.note.house")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(AroTheme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 7) {
                        roleBadge(
                            profile.kind == .local
                                ? "Library stored here"
                                : "Remote library",
                            systemImage: profile.kind == .local ? nil : "network"
                        )
                        if profile.kind == .local, profile.sharingEnabled {
                            roleBadge("Sharing enabled", systemImage: nil)
                        }
                    }
                    Label(
                        primaryStatus(profile),
                        systemImage: primaryStatusIcon(profile)
                    )
                    .foregroundStyle(primaryStatusColor(profile))
                    HStack(spacing: 8) {
                        Text(
                            "\(library.allSongs.count) songs · Last updated just now"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if profile.kind == .remote, let baseURL = profile.baseURL {
                        Text(connectionDetail(baseURL))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if profile.kind == .local {
                        Text(libraryDescription(profile))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if profile.kind == .local,
                       let localServersError = localServers.errorMessage {
                        Label(localServersError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if profile.kind == .local {
                        if !profile.sharingEnabled {
                            Button("Enable Sharing") {
                                enableSharing()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        if needsCredentialRepair(profile) {
                            Button("Repair Connection") {
                                beginRepairingConnection(profile)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Check for Updates") {
                                Task { await performSync(profile) }
                            }
                            .disabled(isSyncing)
                        }
                    }
                    libraryManagementMenu(profile)
                }
            }
        }
    }

    private func libraryManagementMenu(
        _ activeProfile: LibraryProfile
    ) -> some View {
        Menu {
            if registry.profiles.count > 1 {
                Section("Switch Library") {
                    ForEach(registry.profiles) { profile in
                        Button {
                            activateProfile(profile)
                        } label: {
                            if profile.id == registry.activeProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            }

            Button("Create New Library…") {
                showingCreateLibrary = true
            }

            Button("Connect to an Existing Library…") {
                connectionInitialAddress = ""
                showingConnect = true
            }

            Divider()

            Button("Export Library…") {
                beginExport(activeProfile)
            }

            if activeProfile.kind == .local, activeProfile.sharingEnabled {
                Button("Stop Sharing", role: .destructive) {
                    stopSharing(activeProfile)
                }
            }

            if activeProfile.kind == .remote {
                Button("Forget This Library", role: .destructive) {
                    profileToForget = activeProfile
                }
            }
        } label: {
            Label("Manage Libraries", systemImage: "ellipsis.circle")
        }
    }

    private func connectedDevicesCard(_ profile: LibraryProfile) -> some View {
        SettingsCard(title: "Connected Devices") {
            if pairedDevices.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Use your library on another device",
                        systemImage: "macbook.and.iphone"
                    )
                } description: {
                    Text(
                        "Add your phone or another computer to access this library and keep music available offline."
                    )
                } actions: {
                    Button("Add a Device") {
                        if profile.sharingEnabled && sharingIsAvailable {
                            beginAddingDevice()
                        } else {
                            enableSharing(openPairingAfterStart: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
            } else {
                ForEach(pairedDevices) { device in
                    HStack(spacing: 14) {
                        Image(systemName: "laptopcomputer")
                            .font(.title2)
                            .frame(width: 42, height: 42)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.headline)
                            Text(deviceDescription(device))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button(
                                device.allowsContributions
                                    ? "Stop Allowing Music Contributions"
                                    : "Allow Music Contributions"
                            ) {
                                setContribution(
                                    for: device,
                                    allowed: !device.allowsContributions
                                )
                            }
                            Button("Remove Device", role: .destructive) {
                                deviceToRemove = device
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("More options for \(device.name)")
                    }
                    if device.id != pairedDevices.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func connectionDetail(_ url: URL) -> String {
        guard let host = url.host else {
            return url.absoluteString
        }
        guard let port = url.port else {
            return host
        }
        return "\(host):\(port)"
    }

    private func beginRepairingConnection(_ profile: LibraryProfile) {
        connectionInitialAddress = profile.baseURL?.absoluteString ?? ""
        showingConnect = true
    }

    private func needsCredentialRepair(_ profile: LibraryProfile) -> Bool {
        guard profile.kind == .remote, let hubID = profile.hubID else {
            return false
        }
        do {
            return try FileHubCredentialStore().load(
                hubID: hubID,
                deviceID: libraryDeviceID
            ) == nil
        } catch {
            return true
        }
    }

    private func offlineMusicCard(_ profile: LibraryProfile) -> some View {
        SettingsCard(title: "Streaming & Storage") {
            if profile.kind == .local {
                HStack(spacing: 14) {
                    Image(systemName: "internaldrive")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(
                        "This Mac stores the original library, so no additional offline copy is required."
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                if profile.offlinePolicy == .streamOnly {
                                    Image(
                                        systemName:
                                            "dot.radiowaves.left.and.right"
                                    )
                                }
                                Text(policyTitle(profile.offlinePolicy))
                            }
                            .font(.headline)
                            Text(profile.offlinePolicy == .streamOnly
                                ? "Nothing is retained on this Mac"
                                : "\(formattedBytes(mediaCache.usedBytes)) used, "
                                    + "\(mediaCache.downloadedFileCount) stored files")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage Storage") {
                            showingOfflineSettings = true
                        }
                    }
                    HStack(spacing: 16) {
                        Label(
                            "\(mediaCache.downloadedFileCount) downloaded",
                            systemImage: "arrow.down.circle"
                        )
                        Label(
                            formattedBytes(mediaCache.usedBytes),
                            systemImage: "internaldrive"
                        )
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if profile.offlinePolicy != .streamOnly,
                       !isResilient(profile.offlinePolicy) {
                        ProgressView(
                            value: min(
                                Double(mediaCache.usedBytes),
                                Double(storageLimit(profile))
                            ),
                            total: Double(max(1, storageLimit(profile)))
                        )
                        .accessibilityLabel("Offline storage used")
                        .accessibilityValue(
                            "\(formattedBytes(mediaCache.usedBytes)) of "
                                + formattedBytes(storageLimit(profile))
                        )
                    }
                    if let progress = mediaCache.downloadProgress {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(max(1, progress.total))
                        ) {
                            Text(
                                "Downloading \(progress.completed) of \(progress.total) songs"
                            )
                        }
                    }
                }
            }
        }
    }

    private func isResilient(_ policy: OfflineDownloadPolicy) -> Bool {
        policy == .fullLibrary
    }

    private var advancedSettings: some View {
        SyncSettingsView(
            service: service,
            preferences: preferences,
            mediaCache: mediaCache,
            syncStore: syncStore,
            libraryFiles: libraryFiles,
            activeProfile: registry.activeProfile,
            registry: registry,
            library: library,
            activateProfile: activateProfile
        )
    }

    private var unconfiguredState: some View {
        SettingsCard {
            ContentUnavailableView {
                Label("Choose a music library", systemImage: "music.note.house")
            } description: {
                Text(
                    "Keep music on this Mac or connect to an Aro library elsewhere."
                )
            } actions: {
                Button("Create a Library") {
                    registry.setupDismissed = false
                }
                .buttonStyle(.borderedProminent)
                Button("Connect to an Existing Library") {
                    showingConnect = true
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var sharingIsAvailable: Bool {
        service.isEnabled
            && localServers.servers.contains { $0.kind == .bundledHelper }
    }

    private var controlClient: HubControlClient? {
        let dataLocation = Self.controlDataLocation(
            preferred: preferences.dataLocation,
            servers: localServers.servers
        )
        guard let dataLocation, !dataLocation.isEmpty else { return nil }
        return HubControlClient(
            socketURL: URL(fileURLWithPath: dataLocation)
                .appendingPathComponent("control.sock")
        )
    }

    private var activeServerConnection: LibraryServerConnection? {
        guard let profile = registry.activeProfile else { return nil }
        return LibraryServerConnection.resolve(
            profile: profile,
            operations: syncStore,
            deviceID: libraryDeviceID,
            localAdminToken: preferences.localAdminToken
        )
    }

    static func controlDataLocation(
        preferred: String,
        servers: [LocalAroServer]
    ) -> String? {
        servers.first {
            $0.kind == .bundledHelper && !($0.dataPath ?? "").isEmpty
        }?.dataPath ?? (!preferred.isEmpty ? preferred : nil)
    }

    private func beginAddingDevice() {
        localServers.refresh()
        guard let profile = registry.activeProfile,
              let hubID = profile.hubID,
              let connection = LibraryServerConnection.resolve(
                profile: profile,
                operations: syncStore,
                deviceID: libraryDeviceID,
                localAdminToken: preferences.localAdminToken
              ) else {
            addDeviceError = "Aro cannot find the connection for this library service. "
                + "Restart sharing in Library Service & Storage below, then try again."
            return
        }
        pairingSession = PairingSession(
            client: connection.client,
            hubID: hubID,
            port: profile.baseURL?.port ?? 4848
        )
    }

    private func refresh() async {
        localServers.refresh()
        mediaCache.refreshSummary()
        if let hubID = registry.activeProfile?.hubID,
           let syncStatus = syncStore.syncStatus(hubID: hubID) {
            statusMessage = syncStatus.lastError
        }
        await refreshRemoteTopology()
    }

    private func refreshDevices() async {
        await refreshRemoteTopology()
    }

    private func refreshSources() async {
        await refreshRemoteTopology()
    }

    private func refreshRemoteTopology() async {
        guard let profile = registry.activeProfile,
              let connection = LibraryServerConnection.resolve(
                profile: profile,
                operations: syncStore,
                deviceID: libraryDeviceID,
                localAdminToken: preferences.localAdminToken
              ) else {
            return
        }
        do {
            let snapshot = try await connection.client.topology(
                credential: connection.credential
            )
            remoteTopology = snapshot
            topologyOnline = true
            pairedDevices = snapshot.devices
            sourceFolders = snapshot.sources.map {
                ControlledSourceFolder(
                    sourceID: $0.sourceID,
                    name: $0.name,
                    path: $0.name,
                    available: $0.available,
                    watching: true,
                    lastScanAt: nil,
                    lastError: $0.warning,
                    songCount: $0.songCount ?? 0,
                    missingCount: 0
                )
            }
            statusMessage = nil
            remoteTopologyError = nil
        } catch {
            // Topology is optional diagnostics. A server can still be healthy,
            // stream music, and sync normally when this newer endpoint is absent
            // or briefly unreachable; don't turn the whole library status red.
            remoteTopologyError = error.localizedDescription
            topologyOnline = false
        }
    }

    private func enableSharing(openPairingAfterStart: Bool = false) {
        if var profile = registry.activeProfile, profile.kind == .local {
            profile.sharingEnabled = true
            registry.update(profile)
        }
        if preferences.dataLocation.isEmpty {
            preferences.dataLocation = SyncPreferences.recommendedDataLocation
        }
        service.setEnabled(true)
        statusMessage = "Preparing your library for sharing…"
        Task {
            if let controlClient {
                let port = registry.activeProfile?.baseURL?.port ?? 4848
                try? await controlClient.setConfig(
                    key: "bind",
                    value: "[::]:\(port)"
                )
                try? await controlClient.setConfig(
                    key: "advertise_mdns",
                    value: "true"
                )
            }
            await service.ensureCompatibleHelper(
                dataLocation: preferences.dataLocation
            )
            localServers.refresh()
            if let errorMessage = service.errorMessage {
                statusMessage = errorMessage
            } else {
                statusMessage = nil
            }
            if openPairingAfterStart, service.errorMessage == nil,
               sharingIsAvailable {
                beginAddingDevice()
            }
        }
    }

    private func stopSharing(_ profile: LibraryProfile) {
        guard profile.kind == .local else { return }
        var updated = profile
        updated.sharingEnabled = false
        registry.update(updated)
        Task {
            guard let controlClient else {
                statusMessage = "The local server could not be configured."
                return
            }
            let port = profile.baseURL?.port ?? 4848
            do {
                try await controlClient.setConfig(
                    key: "bind",
                    value: "127.0.0.1:\(port)"
                )
                try await controlClient.setConfig(
                    key: "advertise_mdns",
                    value: "false"
                )
                await service.restartForUpgrade()
                await service.ensureCompatibleHelper(
                    dataLocation: preferences.dataLocation
                )
                statusMessage = service.errorMessage ?? "Sharing is off; the local library server is still running."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func performSync(_ profile: LibraryProfile) async {
        guard !isSyncing else { return }
        guard let hubID = profile.hubID,
              let baseURL = profile.baseURL,
              let membership = syncStore.membership(baseURL: baseURL) else {
            statusMessage = "This library connection needs to be repaired."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        statusMessage = "Checking for updates…"
        syncStore.recordSyncStarted(hubID: hubID)
        do {
            guard let credential = try FileHubCredentialStore().load(
                hubID: hubID,
                deviceID: libraryDeviceID
            ) else {
                throw DevicesError.missingCredential
            }
            let client = AroSyncClient(
                baseURL: baseURL,
                pinnedTLSFingerprint: membership.tlsFingerprint
            )
            let result = try await HubSyncCoordinator(
                hubID: hubID,
                client: client,
                credential: credential,
                operations: syncStore,
                offlineTrackCount: UInt64(
                    mediaCache.downloadedFileCount
                ),
                sourceMode: profile.managedMusicPath == nil
                    ? "referenced"
                    : "managed"
            ).synchronize()
            syncStore.recordSyncSucceeded(hubID: hubID, result: result)
            library.reloadStoredLibrary()
            await mediaCache.apply(
                profile.offlinePolicy,
                storageLimitBytes: profile.storageLimitBytes
            )
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            syncStore.recordSyncFailed(
                hubID: hubID,
                message: error.localizedDescription
            )
        }
    }

    private func beginExport(_ profile: LibraryProfile) {
        Task {
            do {
                if profile.kind == .local {
                    if !sharingIsAvailable {
                        service.setEnabled(true)
                        await service.ensureCompatibleHelper(
                            dataLocation: preferences.dataLocation
                        )
                    }
                }
                guard let connection = LibraryServerConnection.resolve(
                    profile: profile,
                    operations: syncStore,
                    deviceID: libraryDeviceID,
                    localAdminToken: preferences.localAdminToken
                ) else { throw DevicesError.missingCredential }
                let exporter = AroLibraryExporter(
                    client: connection.client,
                    credential: connection.credential,
                    localSongs: library.allSongs,
                    localMediaCache: mediaCache.blobCache,
                    snapshotStore: syncStore
                )
                exportSession = LibraryExportSession(exporter: exporter)
            } catch {
                statusMessage = error.localizedDescription
                if exportStartedService {
                    service.setEnabled(false)
                    exportStartedService = false
                }
            }
        }
    }

    private func finishExportSession() {
        if exportStartedService {
            service.setEnabled(false)
            exportStartedService = false
        }
    }

    private func revoke(_ device: ControlledHubDevice) {
        guard let connection = activeServerConnection else { return }
        Task {
            do {
                try await connection.client.revokeAdminDevice(deviceID: device.deviceID)
                pairedDevices = try await connection.client.adminDevices()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func primaryStatus(_ profile: LibraryProfile) -> String {
        if profile.kind == .local {
            return sharingIsAvailable ? "Library available" : "Local server unavailable"
        }
        return statusMessage == nil ? "Connected, up to date" : statusMessage!
    }

    private func primaryStatusIcon(_ profile: LibraryProfile) -> String {
        if statusMessage != nil { return "exclamationmark.circle" }
        return profile.kind == .local && !sharingIsAvailable
            ? "exclamationmark.circle"
            : "checkmark.circle.fill"
    }

    private func primaryStatusColor(_ profile: LibraryProfile) -> Color {
        statusMessage == nil ? .green : .orange
    }

    private func libraryDescription(_ profile: LibraryProfile) -> String {
        profile.sharingEnabled
            ? "Approved devices can use this library while this Aro library is online."
            : "Turn on sharing when you want to use this library on another device."
    }

    private func roleBadge(_ title: String, systemImage: String?) -> some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AroTheme.violet.opacity(0.13), in: Capsule())
    }

    private func policyTitle(_ policy: OfflineDownloadPolicy) -> String {
        switch policy {
        case .streamOnly: "Stream only"
        case .stream: "Keep recently played"
        case .favourites, .selectedAlbums:
            "Keep favourite albums or songs"
        case .fullLibrary: "Resilient — full library mirrored here"
        }
    }

    private func deviceDescription(
        _ device: ControlledHubDevice
    ) -> String {
        guard device.revokedAt == nil else { return "Access removed" }
        var parts = [device.deviceType ?? "Device"]
        if let lastSeen = device.lastSeenAt {
            parts.append(
                Date.now.timeIntervalSince(lastSeen) < 90
                    ? "Online"
                    : "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
            )
        } else {
            parts.append("Approved")
        }
        if let offline = device.offlineTrackCount {
            parts.append("\(offline) songs offline")
        }
        if device.allowsContributions {
            parts.append("Can add music")
        }
        return parts.joined(separator: " · ")
    }

    private func setContribution(
        for device: ControlledHubDevice,
        allowed: Bool
    ) {
        guard let connection = activeServerConnection else { return }
        Task {
            do {
                try await connection.client.setAdminContribution(
                    deviceID: device.deviceID,
                    allowed: allowed
                )
                pairedDevices = try await connection.client.adminDevices()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func storageLimit(_ profile: LibraryProfile) -> Int64 {
        if let explicit = profile.storageLimitBytes {
            return explicit
        }
        let available = (try? URL(fileURLWithPath: profile.mediaPath)
            .resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage).flatMap(Int64.init)
            ?? CacheEvictionPolicy.defaultLimitBytes * 10
        return CacheEvictionPolicy.automaticLimitBytes(
            availableCapacity: available
        )
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var libraryDeviceID: UUID {
        UserDefaults.standard.string(forKey: "library.deviceID")
            .flatMap(UUID.init(uuidString:)) ?? UUID()
    }

    private func topologySongCount(_ profile: LibraryProfile) -> Int {
        if let count = remoteTopology?.trackCount {
            return Int(clamping: count)
        }
        if profile.kind == .local,
           let count = localServers.servers.first(where: { server in
               server.hubID == profile.hubID || server.kind == .bundledHelper
           })?.trackCount {
            return Int(clamping: count)
        }
        return library.allSongs.count
    }
}

struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.12))
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case overview
    case topology

    var id: Self { self }
    var title: String { self == .overview ? "Overview" : "Topology" }
    var icon: String { self == .overview ? "gearshape" : "point.3.connected.trianglepath.dotted" }
}

private struct PairingSession: Identifiable {
    let id = UUID()
    let client: AroSyncClient
    let hubID: UUID
    let port: Int
}

private enum DevicesError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        "This Mac no longer has the credential for that library. Connect again."
    }
}
