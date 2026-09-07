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

import CoreGraphics
import Foundation

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let ownerName: String

    public init(id: CGWindowID, title: String, ownerName: String) {
        self.id = id
        self.title = title
        self.ownerName = ownerName
    }
}

public enum WindowListHelper {
    public static func listWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seen = Set<String>()
        var windows: [WindowInfo] = []

        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let rawID = entry[kCGWindowNumber as String] as? NSNumber,
                  let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                  let owner = entry[kCGWindowOwnerName as String] as? String, owner != "MeetingQ"
            else { continue }

            var bounds = CGRect.zero
            if let dict = entry[kCGWindowBounds as String] as? [String: Any] {
                bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
            }
            guard bounds.width >= 200, bounds.height >= 100 else { continue }

            let key = owner + "|" + title
            guard seen.insert(key).inserted else { continue }

            windows.append(WindowInfo(id: CGWindowID(rawID.uint32Value), title: title, ownerName: owner))
        }

        return windows.sorted {
            $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending
                || ($0.ownerName == $1.ownerName && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending)
        }
    }

    public static func windowID(forTitle title: String) -> CGWindowID? {
        listWindows().first { $0.title.localizedCaseInsensitiveContains(title) }?.id
    }
}
