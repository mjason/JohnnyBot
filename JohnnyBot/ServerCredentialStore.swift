import Foundation
import Security

enum ServerCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "xyz.mj0.JohnnyBot.mqtt",
         kSecAttrAccount as String: "device-ed25519"]
    }

    static func deviceKey() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data, data.count == 32 else { throw ACPFailure(message: "设备密钥格式无效") }
        return data
    }

    static func installDeviceKey(_ key: Data) throws -> Data {
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try deviceKey() { return existing }
        try check(status)
        return key
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        throw ACPFailure(message: SecCopyErrorMessageString(status, nil) as String? ?? "无法访问设备密钥")
    }
}
