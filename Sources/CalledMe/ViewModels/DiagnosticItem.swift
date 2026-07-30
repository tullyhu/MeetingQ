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
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    public var iconColor: Color {
        switch state {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .running: return .accentColor
        case .pending: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    public var detailColor: Color {
        switch state {
        case .error: return .red
        case .warning: return .orange
        case .ok: return .green
        default: return .secondary
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
