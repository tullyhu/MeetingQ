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

public enum LlmProfileStore {
    public static func load() -> [LlmProfile] {
        guard let json = KeychainStorage.load(StoreKeys.llmProfiles),
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([LlmProfile].self, from: data)
        } catch {
            return []
        }
    }

    public static func save(_ profiles: [LlmProfile]) {
        do {
            let data = try JSONEncoder().encode(profiles)
            if let json = String(data: data, encoding: .utf8) {
                KeychainStorage.save(StoreKeys.llmProfiles, value: json)
            }
        } catch {
        }
    }

    public static func active() -> LlmProfile? {
        load().first(where: \.isActive)
    }
}
