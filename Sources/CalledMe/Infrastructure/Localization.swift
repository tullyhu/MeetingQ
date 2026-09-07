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

public enum AppLanguage: String, CaseIterable {
    case zh = "zh"
    case en = "en"

    public static var current: AppLanguage {
        if let cached = _cached { return cached }
        let raw = KeychainStorage.load(StoreKeys.appLanguage) ?? "zh"
        let lang = AppLanguage(rawValue: raw) ?? .zh
        _cached = lang
        return lang
    }

    private static var _cached: AppLanguage?

    public static func set(_ lang: AppLanguage) {
        KeychainStorage.save(StoreKeys.appLanguage, value: lang.rawValue)
        _cached = lang
    }

    public static var needsPick: Bool {
        KeychainStorage.load(StoreKeys.appLanguage) == nil
    }

    public var isEnglish: Bool { self == .en }
}

public func tr(_ zh: String, _ en: String) -> String {
    AppLanguage.current.isEnglish ? en : zh
}
