import Foundation
import Security

/// The three connection settings (base URL + both Cloudflare Access values)
/// live ONLY in the keychain (kSecClassGenericPassword) — never UserDefaults,
/// never plist, never logs.
enum SyncKeychain {
    private static let service = "com.cjwillin.HealthSync.ingest"
    private static let baseURLAccount = "baseURL"
    private static let clientIdAccount = "CF-Access-Client-Id"
    private static let clientSecretAccount = "CF-Access-Client-Secret"

    static func save(baseURL: String, clientId: String, clientSecret: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return false }
        guard !clientId.isEmpty, !clientSecret.isEmpty else { return false }
        return save(baseURLAccount, value: trimmed)
            && save(clientIdAccount, value: clientId)
            && save(clientSecretAccount, value: clientSecret)
    }

    static func clear() {
        for account in [baseURLAccount, clientIdAccount, clientSecretAccount] {
            SecItemDelete(itemQuery(account))
        }
    }

    /// Returns a ready-to-use config, or nil unless all three values are
    /// present and the base URL parses.
    static func loadConfig() -> SyncConfig? {
        guard let base = read(baseURLAccount),
              let url = URL(string: base), url.scheme != nil, url.host != nil,
              let id = read(clientIdAccount),
              let secret = read(clientSecretAccount) else { return nil }
        return SyncConfig(baseURL: url, credentials: UploadCredentials(clientId: id, clientSecret: secret))
    }

    static func hasCredentials() -> Bool { loadConfig() != nil }

    // MARK: - Item helpers

    private static func save(_ account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(itemQuery(account) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = itemQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func read(_ account: String) -> String? {
        var query = itemQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func itemQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
