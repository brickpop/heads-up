import Foundation
import HeadsUpCore
import Security

/// Endpoint tokens in the login keychain (ADR-001 §6.4, Scan's ruling): a generic password per
/// endpoint, service `<bundle id>.endpoint`, account = the endpoint's id. The mask is the
/// item's comment, so listing endpoints reads attributes only and never prompts.
///
/// What protects a token here is the item's access list (only the app that created it, by its
/// designated requirement, reads it without a prompt) and the login keychain being locked
/// while the user is logged out. Accessibility classes don't apply to this keychain, so none
/// is set, and the item is never synchronizable. The data-protection keychain would need an
/// entitlement the app doesn't have (F8).
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    init(bundleID: String = Bundle.main.bundleIdentifier ?? "HeadsUp") {
        service = "\(bundleID).endpoint"
    }

    func token(for endpointID: String) throws(SecretStoreError) -> String? {
        var query = item(endpointID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String, for endpointID: String) throws(SecretStoreError) {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrComment as String: TokenMask.make(token),
        ]
        var status = SecItemUpdate(item(endpointID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item(endpointID).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    func removeToken(for endpointID: String) throws(SecretStoreError) {
        let status = SecItemDelete(item(endpointID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    func mask(for endpointID: String) -> String? {
        var query = item(endpointID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrComment as String] as? String
    }

    /// The query that names one endpoint's item.
    private func item(_ endpointID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointID,
        ]
    }
}
