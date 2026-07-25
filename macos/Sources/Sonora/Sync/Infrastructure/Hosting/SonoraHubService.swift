import Foundation
import Observation
import ServiceManagement
import SonoraCommon

@MainActor
@Observable
final class SonoraHubService {
    private let service = SMAppService.agent(
        plistName: "com.sonora.server.plist"
    )

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

    var statusLabel: String {
        switch status {
        case .notRegistered:
            "Not running"
        case .enabled:
            "Running"
        case .requiresApproval:
            "Approval required in Login Items"
        case .notFound:
            "Helper is not included in this build"
        @unknown default:
            "Unknown"
        }
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
    }

    private let defaults: UserDefaults

    var dataLocation: String {
        didSet {
            defaults.set(dataLocation, forKey: Key.dataLocation)
            try? MacHubConfigurationWriter(defaults: defaults).write(
                dataLocation: dataLocation
            )
        }
    }
    var importMode: HubImportMode {
        didSet { defaults.set(importMode.rawValue, forKey: Key.importMode) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dataLocation = defaults.string(forKey: Key.dataLocation) ?? ""
        importMode = defaults.string(forKey: Key.importMode)
            .flatMap(HubImportMode.init(rawValue:)) ?? .managed
        replicaMode = defaults.string(forKey: Key.replicaMode)
            .flatMap(SyncReplicaMode.init(rawValue:)) ?? .onDemand
        cacheLimitBytes = defaults.object(forKey: Key.cacheLimit) == nil
            ? CacheEvictionPolicy.defaultLimitBytes
            : defaults.object(forKey: Key.cacheLimit) as? Int64
                ?? CacheEvictionPolicy.defaultLimitBytes
        manualAddress = defaults.string(forKey: Key.manualAddress) ?? ""
    }
}

private struct MacHubConfigurationWriter {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func write(dataLocation: String) throws {
        guard !dataLocation.isEmpty else { return }
        let hubID = stableValue(key: "sync.host.hubID") {
            UUID().uuidString
        }
        let adminToken = stableValue(key: "sync.host.adminToken") {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        let configDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Sonora/Server",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        let escapedDataLocation = dataLocation
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let content = """
        hub_id = "\(hubID)"
        display_name = "\(Host.current().localizedName ?? "Sonora Hub")"
        bind = "0.0.0.0:4848"
        data_dir = "\(escapedDataLocation)"
        tls_cert = "\(escapedDataLocation)/tls/cert.pem"
        tls_key = "\(escapedDataLocation)/tls/key.pem"
        control_socket = "\(escapedDataLocation)/control.sock"
        admin_token = "\(adminToken)"
        advertise_mdns = true
        """
        let configURL = configDirectory.appendingPathComponent("sonora.toml")
        try Data(content.utf8).write(
            to: configURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
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
