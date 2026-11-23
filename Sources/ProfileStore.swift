import Foundation
import Security

enum ProfileStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "RouteFork",
        kSecAttrAccount as String: "proxy-profile"
    ]

    static func load() throws -> ProxyProfile? {
        let request = query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, value in value }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.unavailable }
        return try ProxyProfile(String(decoding: data, as: UTF8.self))
    }

    static func save(_ profile: ProxyProfile) throws {
        let secret = Data(profile.value.utf8)
        let update = [kSecValueData as String: secret]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let request = query.merging(update) { _, value in value }
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.unavailable }
    }

    private enum StoreError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Не удалось открыть профиль в Связке ключей. Разблокируй Связку ключей macOS и повтори."
        }
    }
}
