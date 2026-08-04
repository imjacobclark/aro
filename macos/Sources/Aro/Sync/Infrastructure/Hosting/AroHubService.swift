import Foundation
import Observation
import OSLog
import ServiceManagement
import AroCommon

enum LocalServerState: Sendable, Equatable {
    case starting
    case online
    case recovering
    case needsApproval
    case unavailable(String)
}

@MainActor
@Observable
final class AroHubService {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "HubService"
    )

    private let service = SMAppService.agent(
        plistName: "com.aro.server.plist"
    )
    private let fileManager = FileManager.default

    var errorMessage: String?
    var serverState: LocalServerState = .starting

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
            serverState = enabled ? .starting : .unavailable("Server disabled")
        } catch {
            errorMessage = error.localizedDescription
            serverState = service.status == .requiresApproval
                ? .needsApproval
                : .unavailable(error.localizedDescription)
        }
    }

    /// How many times to attempt re-registration, and how long to wait between tries.
    /// Registration legitimately fails for a short window right after an install:
    /// `ditto` replaces the app bundle underneath a `ServiceManagement` daemon that
    /// still has the *previous* build's code signature cached, and until it
    /// re-evaluates the new one it rejects the registration. A single attempt
    /// therefore loses the race on the first launch after every install — which is
    /// precisely when re-registering matters most — and the helper then stays
    /// unregistered for that whole session, SIGKILLed on each respawn as "Code
    /// Signature Invalid", until the app happens to be relaunched.
    private static let registrationAttempts = 5
    private static let registrationRetryDelay = Duration.milliseconds(400)

    func restartForUpgrade() async {
        Self.logger.info("restarting Background Service LaunchAgent")
        do {
            try await service.unregister()
        } catch {
            // An unregister failure is not itself fatal — the service may already be
            // deregistered, which is the state we want anyway. Registration below is
            // what actually has to succeed.
            Self.logger.info(
                "Background Service unregister reported: \(error.localizedDescription, privacy: .public)"
            )
        }
        // `for…where` filters iterations rather than breaking, so the previous
        // version always burned its full budget instead of proceeding as soon as the
        // service had actually deregistered.
        for _ in 0 ..< 20 {
            guard service.status != .notRegistered else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        var lastError: (any Error)?
        for attempt in 1 ... Self.registrationAttempts {
            do {
                try service.register()
                errorMessage = nil
                Self.logger.info(
                    "Background Service LaunchAgent re-registered on attempt \(attempt, privacy: .public)"
                )
                return
            } catch {
                lastError = error
                Self.logger.warning(
                    "Background Service registration attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if attempt < Self.registrationAttempts {
                    try? await Task.sleep(for: Self.registrationRetryDelay)
                }
            }
        }

        let description = lastError?.localizedDescription ?? "unknown error"
        Self.logger.error(
            "Background Service LaunchAgent restart failed after \(Self.registrationAttempts, privacy: .public) attempts: \(description, privacy: .public)"
        )
        errorMessage = "The Background Service was updated but could not be "
            + "restarted: \(description)"
    }

    func ensureCompatibleHelper(dataLocation: String) async {
        guard !dataLocation.isEmpty else { return }
        serverState = .recovering
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
                serverState = .unavailable(errorMessage ?? error.localizedDescription)
                return
            }
        }
        guard isEnabled else {
            serverState = service.status == .requiresApproval
                ? .needsApproval
                : .unavailable("The local library server is not enabled.")
            return
        }
        guard SyncPreferences.isSupportedHelperLocation(dataLocation) else {
            errorMessage = SyncPreferences.protectedLocationMessage
            serverState = .unavailable(SyncPreferences.protectedLocationMessage)
            return
        }
        // Always restarts the LaunchAgent once per app launch, rather than only
        // when the currently running helper is unreachable/incompatible. SMAppService
        // validates a helper's ad-hoc code signature at *registration* time, not on
        // every relaunch — if `aro-server`'s binary changed since the last
        // registration (any app update changes it, since ad-hoc signing hashes
        // binary content) but the previously registered helper process is still
        // alive and responding fine, skipping this leaves the registration stale
        // until that process happens to exit for any reason, at which point macOS's
        // launch-constraint enforcement SIGKILLs it on respawn with "Code Signature
        // Invalid" (observed directly, recurring — see
        // `aro_macos_helper_relaunch_requires_quit` in the project's notes). A short
        // unregister/register round-trip once per launch is cheap next to that.
        let client = HubControlClient(
            socketURL: URL(fileURLWithPath: dataLocation)
                .appendingPathComponent("control.sock")
        )

        // Retries the *whole* unregister/register cycle, not just registration.
        // `register()` reporting success is not evidence the helper actually runs:
        // right after an install, `smd` accepts the registration while still holding
        // the previous build's cached code signature, then launch-constraint
        // enforcement SIGKILLs every spawn as "Code Signature Invalid"
        // (`OS_REASON_CODESIGNING`, exit 78/EX_CONFIG, with `runs` climbing in
        // `launchctl print`). Re-registering once the cache has caught up is what
        // actually clears it — which is why manually quitting and relaunching the app
        // has been the only reliable recovery. Doing that here makes the app
        // self-heal on the launch where it matters instead of leaving the helper dead
        // for the whole session.
        for attempt in 1 ... Self.helperStartAttempts {
            await restartForUpgrade()
            if errorMessage == nil, await waitForCompatibleHelper(client) {
                errorMessage = nil
                serverState = .online
                Self.logger.info(
                    "Background Service listening after attempt \(attempt, privacy: .public)"
                )
                return
            }
            Self.logger.warning(
                "Background Service not listening after attempt \(attempt, privacy: .public)"
            )
            if attempt < Self.helperStartAttempts {
                try? await Task.sleep(for: Self.helperStartRetryDelay)
            }
        }

        Self.logger.error("Background Service did not start listening after restart")
        errorMessage = "The Aro Background Service is enabled but did not start "
            + "listening. Use Restart Background Service in Advanced Devices settings."
        serverState = service.status == .requiresApproval
            ? .needsApproval
            : .unavailable(errorMessage ?? "The local library server is unavailable.")
    }

    /// How many full unregister/register/verify cycles to run before giving up, and
    /// how long to pause between them — long enough for `smd` to re-evaluate a
    /// just-replaced bundle's signature. See the call site for why one cycle isn't
    /// enough.
    private static let helperStartAttempts = 3
    private static let helperStartRetryDelay = Duration.seconds(2)

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
        let configURL = configDirectory.appendingPathComponent("aro.toml")
        let existing = try? String(contentsOf: configURL, encoding: .utf8)
        let dashboard = existing.flatMap(Self.dashboardSection) ?? """
        [dashboard]
        enabled = false
        bind = "0.0.0.0:4849"
        """
        // Fixed at the server's own initialization, same as the standalone CLI's
        // `init --mode`: once `aro.toml` exists, its `storage_mode` is preserved
        // verbatim on every rewrite, never re-derived from `importMode`. Only a
        // brand-new config (no prior file) takes the current preference — this is
        // the only "first write" a storage mode is allowed to come from.
        let storageMode = existing.flatMap(Self.storageMode)
            ?? defaults.string(forKey: "sync.host.importMode")
            ?? "managed"
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
        storage_mode = "\(storageMode)"
        source_rescan_seconds = 300
        acoustid_api_key = "\(escapedAcoustidApiKey)"

        \(dashboard)
        """
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

    private static func dashboardSection(_ contents: String) -> String? {
        let lines = contents.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[dashboard]"
        }) else {
            return nil
        }
        var end = lines.count
        for index in lines.index(after: start)..<lines.endIndex {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                end = index
                break
            }
        }
        return lines[start..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func storageMode(_ contents: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("storage_mode") else { continue }
            guard let start = trimmed.firstIndex(of: "\""),
                  let end = trimmed.lastIndex(of: "\""), start < end else {
                return nil
            }
            return String(trimmed[trimmed.index(after: start)..<end])
        }
        return nil
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
