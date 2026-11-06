import Foundation
import Security

/// Generic-password Keychain storage with an in-memory cache.
///
/// Reading the Keychain can show a blocking macOS prompt (e.g. after the app's code signature
/// changes on rebuild). Values are therefore loaded once in the background at launch via
/// `preload`, and later reads are served from memory so UI code never blocks on the Keychain.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "Cadence"
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    /// Every account Cadence stores; preloaded at launch.
    static let knownAccounts = ["spotify.secret", "lastfm.secret", "lastfm.session"]

    static func preload(completion: @escaping @Sendable () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            for account in knownAccounts { _ = get(account: account) }
            completion()
        }
    }

    static func get(account: String) -> String? {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = read(account: account)
        lock.lock()
        cache[account] = .some(value)
        lock.unlock()
        return value
    }

    static func set(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let normalized = (value?.isEmpty ?? true) ? nil : value
        lock.lock()
        cache[account] = .some(normalized)
        lock.unlock()

        SecItemDelete(base as CFDictionary)
        guard let normalized else { return }
        var add = base
        add[kSecValueData as String] = Data(normalized.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
