import Foundation
import Security

public enum Settings {
    public static let defaultModel = "gemini-3.5-flash-lite"
    // A suite shared by the app and the CLI. It must not equal the app's bundle identifier: UserDefaults crashes on that.
    private static let defaults = UserDefaults(suiteName: "ai.motif.settings") ?? .standard

    public static var model: String {
        get { defaults.string(forKey: "geminiModel").flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel }
        set { defaults.set(newValue, forKey: "geminiModel") }
    }

    public static var recentProjects: [String] {
        get { defaults.stringArray(forKey: "recentProjects") ?? [] }
        set { defaults.set(Array(newValue.prefix(12)), forKey: "recentProjects") }
    }

    public static func noteRecent(_ url: URL) {
        recentProjects = [url.path] + recentProjects.filter { $0 != url.path }
    }

    /// The environment variable wins so the CLI and CI never touch the Keychain.
    /// The Keychain is read at most once per launch: every read of an item can raise a password prompt (and does, for an
    /// ad-hoc signed build, whose signature changes on every rebuild), so the value is held in memory after the first.
    public static var apiKey: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty { return env }
            return keyLock.withLock {
                if !keyLoaded { cachedKey = Keychain.read(account: "gemini-api-key"); keyLoaded = true }
                return cachedKey
            }
        }
        set {
            let value = newValue.flatMap { $0.isEmpty ? nil : $0 }
            keyLock.withLock { cachedKey = value; keyLoaded = true }
            Keychain.write(account: "gemini-api-key", value: value)
        }
    }

    private static let keyLock = NSLock()
    private static var cachedKey: String?
    private static var keyLoaded = false
}

enum Keychain {
    static let service = "ai.motif.app"

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(account: String, value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
