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

public extension Notification.Name {
    static let mmOpenSettings = Notification.Name("CalledMe.OpenSettings")
    static let mmOpenHistory = Notification.Name("CalledMe.OpenHistory")
    static let mmShowMainWindow = Notification.Name("CalledMe.ShowMainWindow")
    static let mmHideMainWindow = Notification.Name("CalledMe.HideMainWindow")
    static let mmRunSelfTest = Notification.Name("CalledMe.RunSelfTest")
    static let mmScreenCapturePermissionGranted = Notification.Name("CalledMe.ScreenCapturePermissionGranted")
}

public enum WindowRouter {
    public static func openSettings() { NotificationCenter.default.post(name: .mmOpenSettings, object: nil) }
    public static func openHistory() { NotificationCenter.default.post(name: .mmOpenHistory, object: nil) }
    public static func showMainWindow() { NotificationCenter.default.post(name: .mmShowMainWindow, object: nil) }
    public static func hideMainWindow() { NotificationCenter.default.post(name: .mmHideMainWindow, object: nil) }
}
