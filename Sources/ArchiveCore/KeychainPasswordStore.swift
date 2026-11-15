import Foundation
import Security

/// Stores and retrieves archive passwords in the native macOS Keychain (`Security.framework`).
public enum KeychainPasswordStore {
    public static let defaultService = "io.github.izusx.sevenzipmac.archive-password"

    private static func accountKey(for archiveURL: URL) -> String {
        archiveURL.standardizedFileURL.path
    }

    public static func password(for archiveURL: URL, service: String = defaultService) -> String? {
        let account = accountKey(for: archiveURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let pwd = String(data: data, encoding: .utf8),
              !pwd.isEmpty else {
            return nil
        }
        return pwd
    }

    @discardableResult
    public static func savePassword(
        _ password: String,
        for archiveURL: URL,
        service: String = defaultService
    ) -> Bool {
        guard let data = password.data(using: .utf8), !password.isEmpty else { return false }
        let account = accountKey(for: archiveURL)

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "7-Zip: \(archiveURL.lastPathComponent)"
        ]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var insertQuery = matchQuery
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrLabel as String] = "7-Zip: \(archiveURL.lastPathComponent)"
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    public static func removePassword(for archiveURL: URL, service: String = defaultService) -> Bool {
        let account = accountKey(for: archiveURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
