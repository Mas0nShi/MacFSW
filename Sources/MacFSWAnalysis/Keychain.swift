import Foundation
import Security

public enum MacFSWKeychainError: Error, LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain operation failed with status \(status)."
        case .invalidData:
            "Keychain returned data that cannot be decoded as UTF-8."
        }
    }
}

/// Generic-password storage. `.dataProtection` items are shared by team and
/// bundle ID, so rebuilt or re-signed apps read them without prompts; the
/// legacy file keychain authorizes one exact code signature and asks the
/// user whenever another build reads it.
public enum MacFSWKeychain {
    public enum Store: Sendable {
        case dataProtection
        case legacyFile
    }

    public static func read(service: String, account: String, in store: Store = .dataProtection) throws -> String? {
        var query = baseQuery(service: service, account: account, store: store)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MacFSWKeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw MacFSWKeychainError.invalidData
        }
        return value
    }

    public static func save(_ value: String, service: String, account: String, in store: Store = .dataProtection) throws {
        if value.isEmpty {
            try delete(service: service, account: account, in: store)
            return
        }

        let data = Data(value.utf8)
        var query = baseQuery(service: service, account: account, store: store)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MacFSWKeychainError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MacFSWKeychainError.unexpectedStatus(addStatus)
        }
    }

    public static func delete(service: String, account: String, in store: Store = .dataProtection) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account, store: store) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MacFSWKeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(service: String, account: String, store: Store) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: store == .dataProtection,
        ]
    }
}
