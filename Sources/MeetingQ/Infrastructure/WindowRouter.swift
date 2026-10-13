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
import Foundation
import CoreGraphics

public extension Notification.Name {
    static let mmOpenSettings = Notification.Name("MeetingQ.OpenSettings")
    static let mmCloseSettings = Notification.Name("MeetingQ.CloseSettings")
    static let mmOpenHistory = Notification.Name("MeetingQ.OpenHistory")
    static let mmShowMainWindow = Notification.Name("MeetingQ.ShowMainWindow")
    static let mmHideMainWindow = Notification.Name("MeetingQ.HideMainWindow")
    static let mmRunSelfTest = Notification.Name("MeetingQ.RunSelfTest")
    static let mmScreenCapturePermissionGranted = Notification.Name("MeetingQ.ScreenCapturePermissionGranted")
    static let mmSessionEnded = Notification.Name("MeetingQ.SessionEnded")
    static let mmMonitoringStateChanged = Notification.Name("MeetingQ.MonitoringStateChanged")
    /// Posted by MeetingWatcherService; userInfo["title"] = window title to capture.
    static let mmAutoStartMeeting = Notification.Name("MeetingQ.AutoStartMeeting")
    /// Monitored meeting window was destroyed (hard end) — stop capture now.
    static let mmMeetingWindowClosed = Notification.Name("MeetingQ.MeetingWindowClosed")
    /// User confirmed the soft-end prompt — stop capture and generate minutes.
    static let mmMeetingEndConfirmed = Notification.Name("MeetingQ.MeetingEndConfirmed")
    /// FloatingWindowViewModel → MeetingWatcherService; object = NSNumber(CGWindowID) or nil.
    static let mmCaptureWindowChanged = Notification.Name("MeetingQ.CaptureWindowChanged")
}

public enum WindowRouter {
    public static func openSettings() { NotificationCenter.default.post(name: .mmOpenSettings, object: nil) }
    public static func closeSettings() { NotificationCenter.default.post(name: .mmCloseSettings, object: nil) }
    public static func openHistory() { NotificationCenter.default.post(name: .mmOpenHistory, object: nil) }
    public static func showMainWindow() { NotificationCenter.default.post(name: .mmShowMainWindow, object: nil) }
    public static func hideMainWindow() { NotificationCenter.default.post(name: .mmHideMainWindow, object: nil) }
    public static func postMonitoringState(_ isMonitoring: Bool) {
        NotificationCenter.default.post(name: .mmMonitoringStateChanged, object: isMonitoring)
    }
    public static func postCaptureWindow(_ id: CGWindowID?) {
        NotificationCenter.default.post(name: .mmCaptureWindowChanged,
                                        object: id.map { NSNumber(value: $0) })
    }
}
