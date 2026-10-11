import Foundation
import Security

@MainActor
final class SecureCredentialStore {
    private let service: String
    init(service: String = "Mach.Remote-TV.pairing") { self.service = service }
    private func query(for deviceID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: deviceID]
    }
    func save(_ credential: Data, for deviceID: String) throws {
        let query = query(for: deviceID)
        let attributes: [String: Any] = [kSecValueData as String: credential,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw RemoteError.keychain(status) }
        } else if update != errSecSuccess { throw RemoteError.keychain(update) }
    }
    func load(for deviceID: String) throws -> Data? {
        var query = query(for: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemoteError.keychain(status) }
        return result as? Data
    }
    func delete(for deviceID: String) throws {
        let status = SecItemDelete(query(for: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteError.keychain(status) }
    }
}
