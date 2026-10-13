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

import MeetingQCore
import AppKit
import ApplicationServices
import Foundation

/// Detects the "currently speaking" participant name by walking the meeting
/// window's accessibility tree — far cheaper and more accurate than OCR.
///
/// Design borrowed from screenpipe's event-driven capture spec:
/// - Accessibility first, OCR as fallback (caller decides the fallback).
/// - Hard time/node budget so a huge Electron AX tree can't stall capture;
///   whatever text was collected within the budget is what we match against.
///
/// Requires macOS Accessibility permission; when not granted every call
/// returns nil and the caller silently falls back to OCR.
public enum ActiveSpeakerAxService {
    /// Budget for a single tree walk. Keeps detection latency predictable even
    /// for apps with 10k+ AX nodes.
    private static let walkBudgetSeconds: TimeInterval = 0.2
    private static let maxVisitedNodes = 4000

    /// Result of one detection pass.
    public struct Detection: Sendable {
        public let speakerName: String
        public let source = "ax"
    }

    /// Walk the AX tree of the app owning `ownerName` (as listed by
    /// `WindowListHelper`) and extract the active speaker's display name.
    /// Returns nil when AX permission is missing, the app is gone, or no
    /// "speaking" indicator is present.
    public static func detectActiveSpeaker(ownerName: String) -> Detection? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == ownerName
        }), let pid = Optional(app.processIdentifier) else { return nil }

        let deadline = Date().addingTimeInterval(walkBudgetSeconds)
        var visited = 0
        var texts: [String] = []
        collectTexts(from: AXUIElementCreateApplication(pid), deadline: deadline,
                     visited: &visited, into: &texts)
        guard let name = extractSpeakerName(from: texts) else { return nil }
        return Detection(speakerName: name)
    }

    // MARK: - AX tree walk

    private static func collectTexts(from element: AXUIElement, deadline: Date,
                                     visited: inout Int, into texts: inout [String]) {
        if visited >= maxVisitedNodes || Date() >= deadline { return }
        visited += 1

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let s = value as? String, looksLikeSpeakingIndicator(s) {
            texts.append(s)
        }
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
           let s = title as? String, looksLikeSpeakingIndicator(s) {
            texts.append(s)
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            if visited >= maxVisitedNodes || Date() >= deadline { return }
            collectTexts(from: child, deadline: deadline, visited: &visited, into: &texts)
        }
    }

    // MARK: - Call-control detection (one-shot meeting-start evidence)

    /// True when the app's AX tree currently shows call-control buttons
    /// (mute/unmute AND hangup/leave). Used ONLY as a one-shot start signal:
    /// controls auto-hide during screen sharing, so absence later means
    /// nothing. Never use this for end detection.
    public static func hasCallControls(ownerName: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == ownerName
        }) else { return false }

        let deadline = Date().addingTimeInterval(walkBudgetSeconds)
        var visited = 0
        var labels: [String] = []
        collectLabels(from: AXUIElementCreateApplication(app.processIdentifier),
                      deadline: deadline, visited: &visited, into: &labels)

        let joined = labels.joined(separator: "\n").lowercased()
        let muteLike = joined.contains("静音") || joined.contains("mute")
            || joined.contains("解除静音") || joined.contains("unmute")
        let hangupLike = joined.contains("挂断") || joined.contains("离开会议")
            || joined.contains("结束会议") || joined.contains("leave") || joined.contains("hang up")
            || joined.contains("end call") || joined.contains("结束通话")
        return muteLike && hangupLike
    }

    private static func collectLabels(from element: AXUIElement, deadline: Date,
                                      visited: inout Int, into labels: inout [String]) {
        if visited >= maxVisitedNodes || Date() >= deadline { return }
        visited += 1

        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
               let s = value as? String, !s.isEmpty, s.count < 40 {
                labels.append(s)
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            if visited >= maxVisitedNodes || Date() >= deadline { return }
            collectLabels(from: child, deadline: deadline, visited: &visited, into: &labels)
        }
    }

    // MARK: - Pattern matching

    /// Cheap pre-filter so we only run regexes on plausible strings.
    private static func looksLikeSpeakingIndicator(_ s: String) -> Bool {
        s.contains("正在发言") || s.contains("发言中")
            || s.lowercased().contains("is speaking")
    }

    /// Extracts a person name from strings like "张三 正在发言",
    /// "李四（发言中）", "Alex is speaking".
    static func extractSpeakerName(from texts: [String]) -> String? {
        for raw in texts {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.count > 60 { continue }

            if let range = s.range(of: #"^(.*?)\s*[（(]?\s*(正在发言|发言中)\s*[）)]?\s*$"#,
                                   options: .regularExpression) {
                var name = String(s[range])
                name = name.replacingOccurrences(of: #"\s*[（(]?\s*(正在发言|发言中)\s*[）)]?\s*$"#,
                                                 with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if isPlausibleName(name) { return name }
            }
            if let range = s.range(of: #"^(.*?)\s+is speaking\s*$"#,
                                   options: [.regularExpression, .caseInsensitive]) {
                let name = String(s[range])
                    .replacingOccurrences(of: #"\s+is speaking\s*$"#, with: "",
                                          options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
                if isPlausibleName(name) { return name }
            }
        }
        return nil
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && trimmed.count <= 20
    }
}
