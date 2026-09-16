import Foundation
import Security

public enum CredentialKind: String, Sendable {
    case password
    case keyPassphrase // stored for when encrypted-key support lands — see OpenSSHEd25519KeyLoader
}

public enum CredentialError: Error, LocalizedError, Sendable {
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }
}

/// Thin, direct wrapper around Keychain Services — no third-party dependency
/// (see `DEPENDENCIES.md`: this is the one area where auditability of every
/// line matters most). Never writes a secret to disk outside the Keychain.
public enum CredentialManager {
    private static let service = "com.techbymoe.TBMFileExplorer.credentials"

    private static func account(_ profileID: UUID, _ kind: CredentialKind) -> String {
        "\(profileID.uuidString).\(kind.rawValue)"
    }

    public static func save(_ secret: String, for profileID: UUID, kind: CredentialKind) throws {
        let account = account(profileID, kind)
        let data = Data(secret.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychainError(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialError.keychainError(updateStatus)
        }
    }

    public static func read(for profileID: UUID, kind: CredentialKind) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(profileID, kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialError.keychainError(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(for profileID: UUID, kind: CredentialKind) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(profileID, kind)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychainError(status)
        }
    }

    /// Removes every credential kind saved for a connection — call when the
    /// connection itself is deleted, so no orphaned Keychain items linger.
    public static func deleteAll(for profileID: UUID) throws {
        for kind: CredentialKind in [.password, .keyPassphrase] {
            try delete(for: profileID, kind: kind)
        }
    }
}
