//
//  KeychainHelper.swift
//  公寓管家 · iOS 钥匙串存取（v1.85）
//  约束：AI API Key 只存本地 Keychain，不写 UserDefaults / 文件 / 云端
//

import Foundation
import Security

enum KeychainHelper {

    /// 存入钥匙串（覆盖式）
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gongyuguanjia.app",
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        // 先删旧值再写入（覆盖语义）
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取钥匙串
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gongyuguanjia.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 清除钥匙串条目
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gongyuguanjia.app",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 是否已存在
    static func exists(key: String) -> Bool {
        load(key: key) != nil
    }
}
