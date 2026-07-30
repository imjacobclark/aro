import Foundation
import Observation
import ServiceManagement
import AroCommon

@MainActor
@Observable
final class AroHubService {
    private let service = SMAppService.agent(
        plistName: "com.aro.server.plist"
    )
    private let fileManager = FileManager.default

    var errorMessage: String?

    var status: SMAppService.Status {
        service.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restartForUpgrade() async {
        do {
            try await service.unregister()
            for _ in 0 ..< 20 where service.status != .notRegistered {
                try await Task.sleep(for: .milliseconds(100))
            }
            try service.register()
            errorMessage = nil
        } catch {
            errorMessage = "The Background Service was updated but could not be "
                + "restarted: \(error.localizedDescription)"
        }
    }

    func ensureCompatibleHelper(dataLocation: String) async {
        guard !dataLocation.isEmpty else { return }
        if !isEnabled,
           UserDefaults.standard.bool(
            forKey: LegacyProductMigration.restoreBackgroundServiceKey
           ) {
            do {
                try service.register()
                UserDefaults.standard.removeObject(
                    forKey: LegacyProductMigration.restoreBackgroundServiceKey
                )
            } catch {
                errorMessage = "Aro migrated your library, but its Background "
                    + "Service needs to be enabled again: "
                    + error.localizedDescription
                return
            }
        }
        guard isEnabled else { return }
        guard SyncPreferences.isSupportedHelperLocation(dataLocation) else {
            errorMessage = SyncPreferences.protectedLocationMessage
            return
        }
        let client = HubControlClient(
            socketURL: URL(fileURLWithPath: dataLocation)
                .appendingPathComponent("control.sock")
        )
        if await waitForCompatibleHelper(client) {
            return
        }
        await restartForUpgrade()
        guard errorMessage == nil else { return }
        guard await waitForCompatibleHelper(client) else {
            errorMessage = "The Aro Background Service is enabled but did not start "
                + "listening. Use Restart Background Service in Advanced Devices settings."
            return
        }
        errorMessage = nil
    }

    private func waitForCompatibleHelper(
        _ client: HubControlClient
    ) async -> Bool {
        for attempt in 0 ..< 25 {
            do {
                try await client.verifyCompatibility()
                return true
            } catch HubControlError.incompatibleHelper {
                return false
            } catch {
                if attempt < 24 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        return false
    }

    var statusLabel: String {
        switch status {
        case .notRegistered:
            "Ready to enable"
        case .enabled:
            "Enabled; waiting for listener"
        case .requiresApproval:
            "Approval required in Login Items"
        case .notFound:
            helperIsBundled
                ? "Ready to enable"
                : "Background Service is not included in this build"
        @unknown default:
            "Unknown"
        }
    }

    private var helperIsBundled: Bool {
        let bundle = Bundle.main.bundleURL
        let helper = bundle.appendingPathComponent(
            "Contents/MacOS/aro-server"
        )
        let plist = bundle.appendingPathComponent(
            "Contents/Library/LaunchAgents/com.aro.server.plist"
        )
        return fileManager.isExecutableFile(atPath: helper.path)
            && fileManager.fileExists(atPath: plist.path)
    }
}

@MainActor
@Observable
final class SyncPreferences {
    private enum Key {
        static let dataLocation = "sync.host.dataLocation"
        static let importMode = "sync.host.importMode"
        static let replicaMode = "sync.replicaMode"
        static let cacheLimit = "sync.cacheLimitBytes"
        static let manualAddress = "sync.manualAddress"
        // Legacy locations, migrated into `LocalHubSecretStore` on first load.
        static let legacyAdminToken = "sync.host.adminToken"
        static let legacyAcoustidApiKey = "sync.host.acoustidApiKey"
    }

    private let defaults: UserDefaults
    private let secretStore: LocalHubSecretStore
    private var secrets: LocalHubSecretStore.Record
    var errorMessage: String?

    static var recommendedDataLocation: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Aro/Library Data",
                isDirectory: true
            )
            .path
    }

    static let protectedLocationMessage =
        "The Background Service cannot use a library-data folder inside "
        + "Desktop, Documents, or Downloads. Choose the recommended Aro "
        + "Library Data location instead. Your music files can remain where they are."

    static func isSupportedHelperLocation(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedDirectories = ["Desktop", "Documents", "Downloads"].map {
            home.appendingPathComponent($0, isDirectory: true)
                .standardizedFileURL.path
        }
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL.path
        return !protectedDirectories.contains {
            candidate == $0 || candidate.hasPrefix($0 + "/")
        }
    }

    var dataLocation: String {
        didSet {
            defaults.set(dataLocation, forKey: Key.dataLocation)
            do {
                secrets = try MacHubConfigurationWriter(
                    defaults: defaults,
                    secretStore: secretStore
                ).write(dataLocation: dataLocation, secrets: secrets)
                errorMessage = nil
            } catch {
                errorMessage = "Aro could not save Background Service settings: "
                    + error.localizedDescription
            }
        }
    }
    var importMode: HubImportMode {
        didSet {
            defaults.set(importMode.rawValue, forKey: Key.importMode)
            do {
                secrets = try MacHubConfigurationWriter(
                    defaults: defaults,
                    secretStore: secretStore
                ).write(dataLocation: dataLocation, secrets: secrets)
                errorMessage = nil
            } catch {
                errorMessage = "Aro could not save Background Service settings: "
                    + error.localizedDescription
            }
        }
    }
    var replicaMode: SyncReplicaMode {
        didSet { defaults.set(replicaMode.rawValue, forKey: Key.replicaMode) }
    }
    var cacheLimitBytes: Int64 {
        didSet { defaults.set(cacheLimitBytes, forKey: Key.cacheLimit) }
    }
    var manualAddress: String {
        didSet { defaults.set(manualAddress, forKey: Key.manualAddress) }
    }
    /// Personal AcoustID API key used for background track identification. Rewrites
    /// `aro.toml` on change, same as `dataLocation`/`importMode` — the running
    /// Background Service picks it up on its next restart.
    var acoustidApiKey: String {
        didSet {
            secrets.acoustidApiKey = acoustidApiKey
            do {
                secrets = try MacHubConfigurationWriter(
                    defaults: defaults,
                    secretStore: secretStore
                ).write(dataLocation: dataLocation, secrets: secrets)
                errorMessage = nil
            } catch {
                errorMessage = "Aro could not save Background Service settings: "
                    + error.localizedDescription
            }
        }
    }
    var localAdminToken: String? {
        secrets.adminToken.isEmpty ? nil : secrets.adminToken
    }

    init(defaults: UserDefaults = .standard, secretStore: LocalHubSecretStore = LocalHubSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
        let loadedSecrets = Self.loadOrMigrateSecrets(defaults: defaults, secretStore: secretStore)
        self.secrets = loadedSecrets
        let storedDataLocation = defaults.string(forKey: Key.dataLocation) ?? ""
        if ProcessInfo.processInfo.environment["ARO_UI_TEST_ROOT"] == nil,
           storedDataLocation.contains("aro-redesign-ui-profile") {
            let repairedDataLocation = Self.recommendedDataLocation
            dataLocation = repairedDataLocation
            defaults.set(repairedDataLocation, forKey: Key.dataLocation)
        } else {
            dataLocation = storedDataLocation
        }
        importMode = defaults.string(forKey: Key.importMode)
            .flatMap(HubImportMode.init(rawValue:)) ?? .managed
        replicaMode = defaults.string(forKey: Key.replicaMode)
            .flatMap(SyncReplicaMode.init(rawValue:)) ?? .onDemand
        cacheLimitBytes = defaults.object(forKey: Key.cacheLimit) == nil
            ? CacheEvictionPolicy.defaultLimitBytes
            : defaults.object(forKey: Key.cacheLimit) as? Int64
                ?? CacheEvictionPolicy.defaultLimitBytes
        manualAddress = defaults.string(forKey: Key.manualAddress) ?? ""
        acoustidApiKey = loadedSecrets.acoustidApiKey
        do {
            secrets = try MacHubConfigurationWriter(
                defaults: defaults,
                secretStore: secretStore
            ).write(dataLocation: dataLocation, secrets: secrets)
        } catch {
            errorMessage = "Aro could not save Background Service settings: "
                + error.localizedDescription
        }
    }

    /// Loads the admin token / AcoustID key from `LocalHubSecretStore`, or —
    /// the first time this runs after upgrading — migrates them out of
    /// UserDefaults (where they were previously stored in plaintext) and
    /// removes the legacy keys.
    private static func loadOrMigrateSecrets(
        defaults: UserDefaults,
        secretStore: LocalHubSecretStore
    ) -> LocalHubSecretStore.Record {
        if let existing = try? secretStore.load() {
            return existing
        }
        let migrated = LocalHubSecretStore.Record(
            adminToken: defaults.string(forKey: Key.legacyAdminToken) ?? "",
            acoustidApiKey: defaults.string(forKey: Key.legacyAcoustidApiKey) ?? ""
        )
        try? secretStore.save(migrated)
        defaults.removeObject(forKey: Key.legacyAdminToken)
        defaults.removeObject(forKey: Key.legacyAcoustidApiKey)
        return migrated
    }
}

private struct MacHubConfigurationWriter {
    private let defaults: UserDefaults
    private let secretStore: LocalHubSecretStore

    init(defaults: UserDefaults, secretStore: LocalHubSecretStore) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    /// Writes `aro.toml` for the Background Service and returns the secrets
    /// record actually used — generating and persisting a fresh admin token
    /// via `LocalHubSecretStore` the first time this runs, if one isn't set yet.
    @discardableResult
    func write(
        dataLocation: String,
        secrets: LocalHubSecretStore.Record
    ) throws -> LocalHubSecretStore.Record {
        guard !dataLocation.isEmpty else { return secrets }
        var secrets = secrets
        if secrets.adminToken.isEmpty {
            secrets.adminToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        try secretStore.save(secrets)
        let hubID = stableValue(key: "sync.host.hubID") {
            UUID().uuidString
        }
        let configDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Aro/Server",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        let escapedDataLocation = dataLocation
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAcoustidApiKey = secrets.acoustidApiKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let content = """
        hub_id = "\(hubID)"
        display_name = "\(Host.current().localizedName ?? "Aro")"
        bind = "0.0.0.0:4848"
        data_dir = "\(escapedDataLocation)"
        tls_cert = "\(escapedDataLocation)/tls/cert.pem"
        tls_key = "\(escapedDataLocation)/tls/key.pem"
        control_socket = "\(escapedDataLocation)/control.sock"
        admin_token = "\(secrets.adminToken)"
        advertise_mdns = true
        storage_mode = "\(defaults.string(forKey: "sync.host.importMode") ?? "managed")"
        source_rescan_seconds = 300
        acoustid_api_key = "\(escapedAcoustidApiKey)"
        """
        let configURL = configDirectory.appendingPathComponent("aro.toml")
        try Data(content.utf8).write(
            to: configURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
        return secrets
    }

    private func stableValue(
        key: String,
        create: () -> String
    ) -> String {
        if let value = defaults.string(forKey: key) {
            return value
        }
        let value = create()
        defaults.set(value, forKey: key)
        return value
    }
}
