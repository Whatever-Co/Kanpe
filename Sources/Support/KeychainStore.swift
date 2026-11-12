import Foundation
import Security

/// macOS Keychain(generic password) に文字列を保存する。account ごとに独立。
struct KeychainStore {
    private static let service = "co.whatever.Kanpe"
    let account: String

    init(account: String) { self.account = account }

    /// 保存できたら true。
    @discardableResult
    func save(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        // 書き換えではなく作り直す：ほかのアプリが先に作った同名の項目に、キーを書き込まないため。
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    var hasKey: Bool { load() != nil }

    static let soniox = KeychainStore(account: "soniox-api-key")
    static let anthropic = KeychainStore(account: "anthropic-api-key")
}
