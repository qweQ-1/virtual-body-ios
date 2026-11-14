//
//  Keychain.swift
//  虚拟身体（VirtualBody）
//
//  职责：把 /api/bind 换来的长期 token 存进 iOS Keychain（kSecClassGenericPassword）。
//  只用 Security 框架，零依赖；所有失败都静默返回 false / nil，绝不抛异常、绝不崩。
//  可访问性用 AfterFirstUnlockThisDeviceOnly：锁屏重启后仍可用，且不随 iCloud 同步。
//

import Foundation
import Security

enum Keychain {

    static let service = "com.virtualbody.app"
    static let account = "vb.binding.token"

    /// 写入（已存在则覆盖）
    @discardableResult
    static func save(_ value: String, service: String = Keychain.service, account: String = Keychain.account) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // 先删再写，避免 errSecDuplicateItem 分支
        _ = delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取
    static func load(service: String = Keychain.service, account: String = Keychain.account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// 删除
    @discardableResult
    static func delete(service: String = Keychain.service, account: String = Keychain.account) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
