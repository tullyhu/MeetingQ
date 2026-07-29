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
import SwiftUI

public enum DiagState: Sendable {
    case pending, running, ok, warning, error
}

extension Color {
    init(mmHex: String) {
        let hex = mmHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

@Observable
public final class DiagnosticItem: Identifiable {
    public let id = UUID()
    public let name: String
    public var state: DiagState = .pending
    public var detail: String = ""

    public init(name: String) {
        self.name = name
    }

    public var icon: String {
        switch state {
        case .pending: return "○"
        case .running: return "⟳"
        case .ok: return "✓"
        case .warning: return "⚠"
        case .error: return "✕"
        }
    }

    public var iconColor: Color {
        switch state {
        case .ok: return Color(mmHex: "4ADE80")
        case .warning: return Color(mmHex: "FBBF24")
        case .error: return Color(mmHex: "FF6B6B")
        case .running: return Color(mmHex: "60A5FA")
        case .pending: return Color(mmHex: "555555")
        }
    }

    public var detailColor: Color {
        switch state {
        case .error: return Color(mmHex: "EF4444")
        case .warning: return Color(mmHex: "D97706")
        case .ok: return Color(mmHex: "16A34A")
        default: return Color(mmHex: "888888")
        }
    }

    public func setPending() { dispatch { self.state = .pending; self.detail = "" } }
    public func setRunning(_ detail: String = tr("检测中...", "Checking...")) { dispatch { self.state = .running; self.detail = detail } }
    public func setOk(_ detail: String) { dispatch { self.state = .ok; self.detail = detail } }
    public func setWarning(_ detail: String) { dispatch { self.state = .warning; self.detail = detail } }
    public func setError(_ detail: String) { dispatch { self.state = .error; self.detail = detail } }

    private func dispatch(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
