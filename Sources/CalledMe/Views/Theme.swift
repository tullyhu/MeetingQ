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

import SwiftUI

public enum MMSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum MMRadius {
    public static let small: CGFloat = 6
    public static let card: CGFloat = 10
    public static let panel: CGFloat = 14
}

extension View {
    public func mmCard(padding: CGFloat = MMSpacing.s) -> some View {
        self
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: MMRadius.card, style: .continuous))
    }

    public func mmSectionHeader() -> some View {
        self
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

public struct MMIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let size: CGFloat

    public init(size: CGFloat = 26) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.5))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: MMRadius.small, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == MMIconButtonStyle {
    public static var mmIcon: MMIconButtonStyle { MMIconButtonStyle() }
    public static func mmIcon(size: CGFloat) -> MMIconButtonStyle { MMIconButtonStyle(size: size) }
}
