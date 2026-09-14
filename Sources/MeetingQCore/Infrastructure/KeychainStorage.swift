// MeetingQ - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 MeetingQ contributors
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
    private static let service = "MeetingQ"
    private static let legacyService = "CalledMe"
    private static let defaults = UserDefaults.standard

    // Secrets (LLM API keys) are AES-GCM encrypted with a machine-bound key
    // (derived from the hardware UUID) and stored in UserDefaults — no keychain
    // access, so macOS never shows an authorization prompt after app updates.
    // Any legacy keychain item is migrated on first read and then deleted.
    private static func isSecret(_ key: String) -> Bool {
        key == StoreKeys.llmProfiles
    }

    private static func defaultsKey(_ key: String) -> String { "MeetingQ.\(key)" }

    public static func save(_ key: String, value: String) {
        guard isSecret(key) else {
            defaults.set(value, forKey: defaultsKey(key))
            keychainDelete(key)
            return
        }
        defaults.set(MachineSecretCipher.encrypt(value), forKey: defaultsKey(key))
        keychainDelete(key)
    }

    public static func load(_ key: String) -> String? {
        if let stored = defaults.string(forKey: defaultsKey(key)) {
            guard isSecret(key) else { return stored }
            guard let decrypted = MachineSecretCipher.decrypt(stored) else {
                defaults.removeObject(forKey: defaultsKey(key))
                return nil
            }
            return decrypted
        }
        if let legacy = defaults.string(forKey: "CalledMe.\(key)") {
            defaults.set(legacy, forKey: defaultsKey(key))
            defaults.removeObject(forKey: "CalledMe.\(key)")
            guard isSecret(key) else { return legacy }
            return MachineSecretCipher.decrypt(legacy)
        }
        guard let legacy = keychainLoad(key, allowUI: false) ?? keychainLoad(key, allowUI: true)
            ?? keychainLoad(key, service: legacyService, allowUI: false)
            ?? keychainLoad(key, service: legacyService, allowUI: true) else { return nil }
        save(key, value: legacy)
        keychainDelete(key, service: legacyService)
        return legacy
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
            defaults.removeObject(forKey: "CalledMe.\(key)")
        }
        for svc in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func keychainLoad(_ key: String, service: String = service, allowUI: Bool) -> String? {
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

    private static func keychainDelete(_ key: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
