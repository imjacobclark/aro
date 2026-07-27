import AppKit
import Foundation
import Security
import SQLite3

enum LegacyProductMigration {
    private static let legacyName = "Sonora"
    private static let currentName = "Aro"
    private static let legacyBundleID = "com.imjacobclark.sonora"
    private static let legacyHelperID = "com.imjacobclark.sonora.server"
    private static let legacyKeychainService =
        "com.imjacobclark.sonora.sync"
    private static let currentKeychainService = "com.imjacobclark.aro.sync"
    private static let markerName = ".aro-brand-migration-v1"
    static let restoreBackgroundServiceKey =
        "migration.restoreAroBackgroundService"

    static func run(
        fileManager: FileManager = .default,
        currentDefaults: UserDefaults = .standard
    ) throws {
        guard ProcessInfo.processInfo.environment["ARO_UI_TEST_ROOT"] == nil
        else {
            return
        }

        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let legacyRoot = support.appendingPathComponent(
            legacyName,
            isDirectory: true
        )
        let currentRoot = support.appendingPathComponent(
            currentName,
            isDirectory: true
        )
        let marker = currentRoot.appendingPathComponent(markerName)

        if !fileManager.fileExists(atPath: marker.path) {
            let helperWasEnabled = try stopLegacyProcesses()
            try migrateDefaults(into: currentDefaults)
            if helperWasEnabled {
                currentDefaults.set(true, forKey: restoreBackgroundServiceKey)
            }
            try migrateApplicationSupport(
                from: legacyRoot,
                to: currentRoot,
                fileManager: fileManager
            )
            try migrateKeychain()

            try fileManager.createDirectory(
                at: currentRoot,
                withIntermediateDirectories: true
            )
            try Data("Aro migration complete\n".utf8).write(
                to: marker,
                options: .atomic
            )
        }

        try repairMigratedDeviceIdentity(defaults: currentDefaults)
        try repairCurrentState(
            applicationSupportRoot: currentRoot,
            defaults: currentDefaults,
            fileManager: fileManager
        )
        currentDefaults.synchronize()
    }

    private static func stopLegacyProcesses() throws -> Bool {
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: legacyBundleID
        ) {
            application.terminate()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !NSRunningApplication.runningApplications(
                withBundleIdentifier: legacyBundleID
              ).isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: legacyBundleID
        ).isEmpty else {
            throw MigrationError.legacyAppStillRunning
        }

        let target = "gui/\(getuid())/\(legacyHelperID)"
        let helperWasEnabled = launchctl(["print", target]) == 0
        _ = launchctl([
            "bootout",
            target,
        ])
        return helperWasEnabled
    }

    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func migrateDefaults(into defaults: UserDefaults) throws {
        guard let legacy = UserDefaults.standard.persistentDomain(
            forName: legacyBundleID
        ) else {
            return
        }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(rewritePropertyList(value), forKey: key)
        }
    }

    private static func rewritePropertyList(_ value: Any) -> Any {
        if let string = value as? String {
            return rewrite(string)
        }
        if let values = value as? [Any] {
            return values.map(rewritePropertyList)
        }
        if let values = value as? [String: Any] {
            return values.mapValues(rewritePropertyList)
        }
        if let data = value as? Data,
           let string = String(data: data, encoding: .utf8),
           (string.first == "{" || string.first == "[") {
            return Data(rewrite(string).utf8)
        }
        return value
    }

    static func rewrite(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "\\/Application Support\\/\(legacyName)\\/",
                with: "\\/Application Support\\/\(currentName)\\/"
            )
            .replacingOccurrences(
                of: "\\/Application Support\\/\(legacyName)",
                with: "\\/Application Support\\/\(currentName)"
            )
            .replacingOccurrences(
                of: "/Application Support/\(legacyName)/",
                with: "/Application Support/\(currentName)/"
            )
            .replacingOccurrences(
                of: "/Application Support/\(legacyName)",
                with: "/Application Support/\(currentName)"
            )
            .replacingOccurrences(
                of: "\(legacyName).sqlite3",
                with: "\(currentName).sqlite3"
            )
            .replacingOccurrences(
                of: "https:\\/\\/sonora-",
                with: "https:\\/\\/aro-"
            )
            .replacingOccurrences(
                of: "https://sonora-",
                with: "https://aro-"
            )
            .replacingOccurrences(of: "sonora.toml", with: "aro.toml")
    }

    static func repairCurrentState(
        applicationSupportRoot: URL,
        defaults: UserDefaults,
        fileManager: FileManager
    ) throws {
        for key in [
            "library.profileRegistry.v1",
            "sync.host.dataLocation",
        ] {
            guard let value = defaults.object(forKey: key) else { continue }
            defaults.set(rewritePropertyList(value), forKey: key)
        }

        guard let enumerator = fileManager.enumerator(
            at: applicationSupportRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }
        for case let url as URL in enumerator
        where url.pathExtension == "sqlite3" {
            try repairMembershipURLs(in: url)
        }
    }

    private static func repairMembershipURLs(in url: URL) throws {
        var connection: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &connection,
            SQLITE_OPEN_READWRITE,
            nil
        )
        guard openStatus == SQLITE_OK, let connection else {
            if let connection {
                sqlite3_close(connection)
            }
            throw MigrationError.database(url.path, openStatus, "open failed")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)

        var statement: OpaquePointer?
        let tableStatus = sqlite3_prepare_v2(
            connection,
            """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table' AND name = 'hub_memberships'
            """,
            -1,
            &statement,
            nil
        )
        guard tableStatus == SQLITE_OK, let statement else {
            throw MigrationError.database(
                url.path,
                tableStatus,
                String(cString: sqlite3_errmsg(connection))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return }

        let updateStatus = sqlite3_exec(
            connection,
            """
            UPDATE hub_memberships
            SET base_url = replace(
                base_url,
                'https://sonora-',
                'https://aro-'
            )
            WHERE base_url LIKE 'https://sonora-%'
            """,
            nil,
            nil,
            nil
        )
        guard updateStatus == SQLITE_OK else {
            throw MigrationError.database(
                url.path,
                updateStatus,
                String(cString: sqlite3_errmsg(connection))
            )
        }
    }

    static func migrateApplicationSupport(
        from legacyRoot: URL,
        to currentRoot: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }

        if !fileManager.fileExists(atPath: currentRoot.path) {
            try fileManager.moveItem(at: legacyRoot, to: currentRoot)
        } else {
            try mergeDirectory(
                from: legacyRoot,
                to: currentRoot,
                fileManager: fileManager
            )
            try fileManager.removeItem(at: legacyRoot)
        }

        try renameLegacyFiles(in: currentRoot, fileManager: fileManager)
        try rewriteConfigurationFiles(in: currentRoot, fileManager: fileManager)
    }

    private static func mergeDirectory(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        for child in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let target = destination.appendingPathComponent(
                child.lastPathComponent
            )
            let isDirectory = try child.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory == true
            if isDirectory, fileManager.fileExists(atPath: target.path) {
                try mergeDirectory(
                    from: child,
                    to: target,
                    fileManager: fileManager
                )
                try fileManager.removeItem(at: child)
            } else if !fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: child, to: target)
            } else if try Data(contentsOf: child) == Data(contentsOf: target) {
                try fileManager.removeItem(at: child)
            } else {
                throw MigrationError.destinationConflict(target.path)
            }
        }
    }

    private static func renameLegacyFiles(
        in root: URL,
        fileManager: FileManager
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let urls = enumerator.compactMap { $0 as? URL }
        for url in urls.sorted(by: { $0.path.count > $1.path.count }) {
            let name = url.lastPathComponent
            let replacement: String?
            if name.hasPrefix("\(legacyName).sqlite3") {
                replacement = name.replacingOccurrences(
                    of: legacyName,
                    with: currentName
                )
            } else if name == "sonora.toml" {
                replacement = "aro.toml"
            } else {
                replacement = nil
            }
            guard let replacement else { continue }
            let target = url.deletingLastPathComponent()
                .appendingPathComponent(replacement)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: url, to: target)
            }
        }
    }

    private static func rewriteConfigurationFiles(
        in root: URL,
        fileManager: FileManager
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for case let url as URL in enumerator
        where url.pathExtension == "toml" {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                continue
            }
            let updated = rewrite(content)
            if updated != content {
                try Data(updated.utf8).write(to: url, options: .atomic)
            }
        }
    }

    private static func migrateKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw MigrationError.keychain(status)
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else {
                continue
            }
            let credentialQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyKeychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var credentialResult: CFTypeRef?
            let credentialStatus = SecItemCopyMatching(
                credentialQuery as CFDictionary,
                &credentialResult
            )
            guard credentialStatus == errSecSuccess,
                  let data = credentialResult as? Data else {
                throw MigrationError.keychain(credentialStatus)
            }
            var destination: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: currentKeychainService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
            ]
            if let description =
                item[kSecAttrDescription as String] as? String
                ?? legacyDeviceID()?.uuidString {
                destination[kSecAttrDescription as String] = description
            }
            let addStatus = SecItemAdd(
                destination as CFDictionary,
                nil
            )
            guard addStatus == errSecSuccess
                    || addStatus == errSecDuplicateItem else {
                throw MigrationError.keychain(addStatus)
            }
        }

        let deleteStatus = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
        ] as CFDictionary)
        guard deleteStatus == errSecSuccess
                || deleteStatus == errSecItemNotFound else {
            throw MigrationError.keychain(deleteStatus)
        }
    }

    /// Credentials created by Sonora are bound to Sonora's device UUID. Early
    /// Aro builds copied the credential but could generate a new UUID before
    /// using it, causing an otherwise healthy migrated connection to receive
    /// HTTP 401. A missing Keychain description identifies those copied
    /// credentials; credentials paired natively in Aro always store one.
    private static func repairMigratedDeviceIdentity(
        defaults: UserDefaults
    ) throws {
        guard let legacyID = legacyDeviceID() else { return }
        if defaults.string(forKey: "library.deviceID")
            .flatMap(UUID.init(uuidString:)) == legacyID {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentKeychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw MigrationError.keychain(status)
        }
        let migratedItems = items.filter {
            $0[kSecAttrDescription as String] == nil
        }
        guard !migratedItems.isEmpty else { return }

        defaults.set(legacyID.uuidString, forKey: "library.deviceID")
    }

    private static func legacyDeviceID() -> UUID? {
        let legacy = UserDefaults.standard.persistentDomain(
            forName: legacyBundleID
        )
        return (legacy?["library.deviceID"] as? String)
            .flatMap(UUID.init(uuidString:))
    }
}

enum MigrationError: LocalizedError {
    case legacyAppStillRunning
    case destinationConflict(String)
    case keychain(OSStatus)
    case database(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .legacyAppStillRunning:
            "Close Sonora before opening Aro so your library can be upgraded safely."
        case let .destinationConflict(path):
            "Aro found different legacy and current files at \(path). Neither file was removed."
        case let .keychain(status):
            "Aro could not migrate paired-device credentials (Keychain status \(status))."
        case let .database(path, status, message):
            "Aro could not repair the migrated connection database at \(path) (SQLite status \(status): \(message))."
        }
    }
}
