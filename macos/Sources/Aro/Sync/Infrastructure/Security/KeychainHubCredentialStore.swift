import Foundation
import Security
import AroCommon

enum HubCredentialError: Error {
    case keychain(OSStatus)
}

struct KeychainHubCredentialStore {
    private let service = "com.imjacobclark.aro.sync"

    func save(_ credential: HubDeviceCredential, hubID: UUID) throws {
        let account = hubID.uuidString
        let data = Data(credential.credential.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrDescription as String: credential.deviceID.uuidString,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw HubCredentialError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw HubCredentialError.keychain(status)
        }
    }

    func load(hubID: UUID, deviceID: UUID) throws -> HubDeviceCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hubID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw HubCredentialError.keychain(status)
        }
        return HubDeviceCredential(deviceID: deviceID, credential: value)
    }

    func remove(hubID: UUID) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hubID.uuidString,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HubCredentialError.keychain(status)
        }
    }
}
