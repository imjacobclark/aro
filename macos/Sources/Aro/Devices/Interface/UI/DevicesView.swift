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
                controlClient: session.client,
                onDevicesChanged: { pairedDevices = $0 }
            )
        }
        .sheet(isPresented: $showingConnect) {
            ConnectLibrarySheet(
                completeConnection: completeRemoteConnection,
                willPauseSharing: registry.activeProfile?.kind == .local
                    && sharingIsAvailable,
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
                if registry.activeProfile?.kind == .local {
                    await refreshDevices()
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let profile = registry.activeProfile {
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
                        if profile.kind == .local, sharingIsAvailable {
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
                        if !sharingIsAvailable {
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

            if activeProfile.kind == .local, sharingIsAvailable {
                Button("Stop Sharing", role: .destructive) {
                    stopSharing(activeProfile)
                }
            }

            if activeProfile.kind == .remote, registry.profiles.count > 1 {
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
                        if sharingIsAvailable {
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
        guard let controlClient else {
            addDeviceError = "Aro cannot find the connection for this library service. "
                + "Restart sharing in Library Service & Storage below, then try again."
            return
        }
        pairingSession = PairingSession(client: controlClient)
    }

    private func refresh() async {
        localServers.refresh()
        mediaCache.refreshSummary()
        if let hubID = registry.activeProfile?.hubID,
           let syncStatus = syncStore.syncStatus(hubID: hubID) {
            statusMessage = syncStatus.lastError
        }
        await refreshDevices()
    }

    private func refreshDevices() async {
        guard let controlClient, sharingIsAvailable else {
            pairedDevices = []
            return
        }
        do {
            pairedDevices = try await controlClient.devices()
        } catch {
            statusMessage = error.localizedDescription
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
            await service.ensureCompatibleHelper(
                dataLocation: preferences.dataLocation
            )
            let profile = registry.activeProfile
            let mode: HubImportMode = profile?.managedMusicPath == nil
                ? .referenced
                : .managed
            preferences.importMode = mode
            var failedFolderCount = 0
            for path in syncStore.activeWatchedFolderPaths {
                do {
                    _ = try await controlClient?.importFolder(
                        path: path,
                        mode: mode
                    )
                } catch {
                    failedFolderCount += 1
                }
            }
            localServers.refresh()
            if let errorMessage = service.errorMessage {
                statusMessage = errorMessage
            } else if failedFolderCount > 0 {
                statusMessage = failedFolderCount == 1
                    ? "1 watched folder could not be shared."
                    : "\(failedFolderCount) watched folders could not be shared."
            } else {
                statusMessage = nil
            }
            if openPairingAfterStart, service.errorMessage == nil,
               failedFolderCount == 0 {
                beginAddingDevice()
            }
        }
    }

    private func stopSharing(_ profile: LibraryProfile) {
        guard profile.kind == .local else { return }
        var updated = profile
        updated.sharingEnabled = false
        registry.update(updated)
        service.setEnabled(false)
        statusMessage = service.errorMessage ?? "Sharing is off"
        Task {
            for _ in 0 ..< 10 {
                localServers.refresh()
                if !sharingIsAvailable {
                    statusMessage = nil
                    pairedDevices = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
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
                let exporter: AroLibraryExporter
                if profile.kind == .local {
                    guard let adminToken = preferences.localAdminToken else {
                        throw DevicesError.missingCredential
                    }
                    if !sharingIsAvailable {
                        exportStartedService = true
                        service.setEnabled(true)
                        for _ in 0 ..< 30 {
                            localServers.refresh()
                            if sharingIsAvailable { break }
                            try await Task.sleep(for: .milliseconds(200))
                        }
                    }
                    exporter = AroLibraryExporter(
                        client: AroSyncClient(
                            localAdminBaseURL: URL(
                                string: "https://127.0.0.1:4848"
                            )!,
                            adminToken: adminToken
                        ),
                        credential: nil
                    )
                } else {
                    guard let hubID = profile.hubID,
                          let baseURL = profile.baseURL,
                          let membership = syncStore.membership(
                            baseURL: baseURL
                          ),
                          let credential = try FileHubCredentialStore()
                            .load(
                                hubID: hubID,
                                deviceID: libraryDeviceID
                            ) else {
                        throw DevicesError.missingCredential
                    }
                    exporter = AroLibraryExporter(
                        client: AroSyncClient(
                            baseURL: baseURL,
                            pinnedTLSFingerprint:
                                membership.tlsFingerprint
                        ),
                        credential: credential,
                        localSongs: library.allSongs,
                        localMediaCache: mediaCache.blobCache
                    )
                }
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
        guard let controlClient else { return }
        Task {
            do {
                try await controlClient.revoke(deviceID: device.deviceID)
                pairedDevices = try await controlClient.devices()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func primaryStatus(_ profile: LibraryProfile) -> String {
        if profile.kind == .local {
            return sharingIsAvailable ? "Library available" : "Stored on this Mac"
        }
        return statusMessage == nil ? "Connected, up to date" : statusMessage!
    }

    private func primaryStatusIcon(_ profile: LibraryProfile) -> String {
        if statusMessage != nil { return "exclamationmark.circle" }
        return profile.kind == .local && !sharingIsAvailable
            ? "internaldrive"
            : "checkmark.circle.fill"
    }

    private func primaryStatusColor(_ profile: LibraryProfile) -> Color {
        statusMessage == nil ? .green : .orange
    }

    private func libraryDescription(_ profile: LibraryProfile) -> String {
        sharingIsAvailable
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
        guard let controlClient else { return }
        Task {
            do {
                try await controlClient.setContribution(
                    deviceID: device.deviceID,
                    allowed: allowed
                )
                pairedDevices = try await controlClient.devices()
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

private struct PairingSession: Identifiable {
    let id = UUID()
    let client: HubControlClient
}

private enum DevicesError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        "This Mac no longer has the credential for that library. Connect again."
    }
}
