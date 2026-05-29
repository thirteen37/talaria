import Foundation
#if canImport(Security)
import Security
#endif

/// Cross-platform wrapper around the OS Keychain for storing SSH passwords.
///
/// Today only the iOS host wires this up — macOS uses the system `ssh`
/// binary, which manages its own credentials (`ssh-agent`, the user's
/// login keychain via `ssh-add --apple-use-keychain`, `~/.ssh/config`).
/// The macOS stub returns nil/no-op so cross-platform call sites compile
/// without `#if os(iOS)` everywhere.
///
/// Keychain semantics:
/// - Items are stored as `kSecClassGenericPassword`.
/// - The lookup reference is a UUID string that lives in the
///   ``ServerProfile/passwordKeychainReference`` field.
/// - The service string isolates these items from any other Keychain use
///   the app may grow later.
public enum PasswordKeychain {
    public enum KeychainError: Error, Sendable {
        case unhandled(OSStatus)
        case unavailable
    }

    /// Service identifier under which all SSH passwords land. Items are
    /// further disambiguated by the per-profile reference UUID.
    public static let service = "com.talaria.Talaria.ssh.password"

    /// Stores `password` under the given reference. Overwrites any existing
    /// value for the same reference. Returns silently on macOS (where the
    /// password path isn't supported by the system-ssh transport).
    public static func set(reference: String, password: String) throws {
        #if os(iOS)
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        // Try update first; SecItemUpdate fails with errSecItemNotFound when
        // no entry exists. In that case fall through to SecItemAdd.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandled(updateStatus)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unhandled(addStatus)
        }
        #else
        // macOS doesn't store SSH passwords for us — system-ssh handles its
        // own credential resolution. This is a no-op so call sites stay
        // platform-agnostic.
        _ = (reference, password)
        #endif
    }

    /// Returns the stored password for `reference`, or nil if no entry
    /// exists. Returns nil on macOS regardless of any reference value.
    public static func get(reference: String) -> String? {
        #if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        _ = reference
        return nil
        #endif
    }

    /// Deletes the stored password for `reference`. No-op on macOS and
    /// when the entry doesn't exist.
    public static func delete(reference: String) throws {
        #if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
        #else
        _ = reference
        #endif
    }
}
