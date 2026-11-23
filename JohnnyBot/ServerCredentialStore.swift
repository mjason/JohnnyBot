import Foundation
import Security

enum ServerCredentialStore {
    private static func query(_ address: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.mj0.JohnnyBot.acp",
            kSecAttrAccount as String: address
        ]
    }

    static func token(for address: String) throws -> String? {
        var request = query(address)
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ACPFailure(message: "钥匙串中的服务器令牌无法读取")
        }
        return token
    }

    static func save(_ token: String, for address: String) throws {
        let key = query(address)
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecDuplicateItem {
                try check(SecItemUpdate(key as CFDictionary, attributes as CFDictionary))
            } else {
                try check(added)
            }
        } else {
            try check(status)
        }
    }

    static func remove(_ address: String) throws {
        let status = SecItemDelete(query(address) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        throw ACPFailure(message: "无法访问服务器令牌的钥匙串项目。\(detail)")
    }
}
