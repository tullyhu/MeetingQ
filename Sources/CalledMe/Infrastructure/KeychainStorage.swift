// CalledMe - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 CalledMe contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Security

public enum KeychainStorage {
    private static let service = "CalledMe"
    private static let defaults = UserDefaults.standard

    // Only real secrets stay in the keychain: its ACL trusts the app binary,
    // so every update triggers one macOS authorization prompt per stored item.
    // Plain configuration lives in UserDefaults, which is signature-independent.
    private static func isSecret(_ key: String) -> Bool {
        key == StoreKeys.llmProfiles
    }

    private static func defaultsKey(_ key: String) -> String { "CalledMe.\(key)" }

    public static func save(_ key: String, value: String) {
        guard isSecret(key) else {
            defaults.set(value, forKey: defaultsKey(key))
            keychainDelete(key)
            return
        }
        keychainSave(key, value: value)
    }

    public static func load(_ key: String) -> String? {
        guard isSecret(key) else {
            if let value = defaults.string(forKey: defaultsKey(key)) { return value }
            guard let legacy = keychainLoad(key, allowUI: false) ?? keychainLoad(key, allowUI: true) else { return nil }
            defaults.set(legacy, forKey: defaultsKey(key))
            keychainDelete(key)
            return legacy
        }
        return keychainLoad(key, allowUI: true)
    }

    public static func delete(_ key: String) {
        defaults.removeObject(forKey: defaultsKey(key))
        keychainDelete(key)
    }

    public static func saveBool(_ key: String, _ value: Bool) {
        save(key, value: value ? "1" : "0")
    }

    public static func loadBool(_ key: String) -> Bool {
        load(key) == "1"
    }

    public static func loadBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let raw = load(key) else { return defaultValue }
        return raw == "1"
    }

    public static func clearAll() {
        for key in StoreKeys.all {
            defaults.removeObject(forKey: defaultsKey(key))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
        }
    }

    private static func keychainSave(_ key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
            }
        } else if status != errSecSuccess {
        }
    }

    private static func keychainLoad(_ key: String, allowUI: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
