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

import AppKit
import AVFoundation
import CoreGraphics
import Speech

@MainActor
public final class PermissionManager {
    public static let shared = PermissionManager()

    private var watcherTask: Task<Void, Never>?
    private var screenGrantedAtLaunch = true
    private var restartPromptShowing = false

    private init() {}

    public func requestInitialPermissions() {
        let screenGranted = PermissionsHelper.screenCaptureGranted()
        screenGrantedAtLaunch = screenGranted

        Task { @MainActor in
            if PermissionsHelper.speechAuthorizationStatus() == .notDetermined {
                let status = await PermissionsHelper.requestSpeechAuthorization()
            }

            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                let mic = await PermissionsHelper.requestMicrophone()
            }

            if !PermissionsHelper.screenCaptureGranted() {
                PermissionsHelper.requestScreenCapture()
                startScreenPermissionWatcher()
            }
        }
    }

    public func startScreenPermissionWatcher() {
        guard watcherTask == nil else { return }
        watcherTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if PermissionsHelper.screenCaptureGranted() {
                    self.watcherTask = nil
                    NotificationCenter.default.post(name: .mmScreenCapturePermissionGranted, object: nil)
                    if !self.screenGrantedAtLaunch {
                        self.promptRestart()
                    }
                    return
                }
            }
        }
    }

    private func promptRestart() {
        guard !restartPromptShowing else { return }
        restartPromptShowing = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.restartPromptShowing else { return }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }

        let alert = NSAlert()
        alert.messageText = tr("屏幕录制权限已授予", "Screen Recording Permission Granted")
        alert.informativeText = tr("需要重启 MeetingQ 使权限生效，将在 10 秒后自动重启。",
                                   "MeetingQ needs to restart for the permission to take effect. It will restart automatically in 10 seconds.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("立即重启", "Restart Now"))
        alert.addButton(withTitle: tr("稍后手动重启", "Restart Later Manually"))
        let response = alert.runModal()
        restartPromptShowing = false

        if response == .alertFirstButtonReturn {
            relaunch()
        }
    }

    public func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 0.5; /usr/bin/open -n \"\(bundlePath)\""
        if let sh = try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]) {
            sh.terminationHandler = nil
        } else {
        }
        NSApp.terminate(nil)
    }
}
