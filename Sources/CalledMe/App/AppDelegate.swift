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

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusBar: StatusBarController?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let settingsVM = SettingsViewModel()
    private var historyWindow: NSWindow?
    private let historyVM = HistoryViewModel()
    private var privacyWindow: NSWindow?
    private var languageWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceGuard.ensureSingleInstance() else {
            NSApp.terminate(nil)
            return
        }

        _ = DataStore.shared
        _ = AppServices.shared

        statusBar = StatusBarController()
        statusBar?.onQuit = { NSApp.terminate(nil) }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .mmShowMainWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showMainWindow() }
        }
        nc.addObserver(forName: .mmHideMainWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mainWindow?.orderOut(nil) }
        }
        nc.addObserver(forName: .mmOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showSettingsWindow() }
        }
        nc.addObserver(forName: .mmCloseSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settingsWindow?.close() }
        }
        nc.addObserver(forName: .mmOpenHistory, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showHistoryWindow() }
        }

        if AppLanguage.needsPick {
            showLanguageWindow()
        } else if PrivacyNoticeView.needsShow() {
            showPrivacyWindow()
        } else if OnboardingView.needsShow() {
            showOnboardingWindow()
        } else {
            showMainWindow()
            PermissionManager.shared.requestInitialPermissions()
        }

        if ProcessInfo.processInfo.environment["MM_SELFTEST_ON_LAUNCH"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                NotificationCenter.default.post(name: .mmRunSelfTest, object: nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == settingsWindow, settingsVM.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = tr("设置尚未保存", "Unsaved Changes")
        alert.informativeText = tr("你修改了设置但尚未保存。关闭前要保存吗？",
                                   "You have unsaved changes. Do you want to save them before closing?")
        alert.addButton(withTitle: tr("保存并关闭", "Save and Close"))
        alert.addButton(withTitle: tr("不保存", "Don't Save"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            settingsVM.saveSettings()
            return true
        case .alertSecondButtonReturn:
            settingsVM.loadFromStorage()
            return true
        default:
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PopupManager.shared.dismissAll()
        DataStore.shared.endMonitoringSessions()
        let audio = AppServices.shared.audio
        let asr = AppServices.shared.asr
        let screen = AppServices.shared.screen
        let group = DispatchGroup()
        group.enter()
        Task {
            await audio.stop()
            await asr.disconnect()
            await screen.stop()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 3)
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.level = .floating
            w.minSize = NSSize(width: 260, height: 340)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FloatingWindowView())
            w.center()
            positionBottomRight(w)
            mainWindow = w
        }
        if let w = mainWindow, !w.isVisible {
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 1
            }
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            w.title = tr("设置", "Settings")
            w.minSize = NSSize(width: 640, height: 560)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(vm: settingsVM))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHistoryWindow() {
        if historyWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = tr("历史会议", "Meeting History")
            w.minSize = NSSize(width: 560, height: 380)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HistoryView(vm: historyVM))
            w.center()
            historyWindow = w
        }
        historyVM.refresh()
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPrivacyWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        w.title = tr("隐私声明", "Privacy Notice")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PrivacyNoticeView(onAccept: { [weak self, weak w] in
            w?.orderOut(nil)
            if OnboardingView.needsShow() {
                self?.showOnboardingWindow()
            } else {
                self?.showMainWindow()
                PermissionManager.shared.requestInitialPermissions()
            }
        }))
        w.center()
        privacyWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showLanguageWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        w.title = "CalledMe"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LanguagePickerView(onPicked: { [weak self, weak w] in
            w?.orderOut(nil)
            self?.showPrivacyWindow()
        }))
        w.center()
        languageWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboardingWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = tr("欢迎使用 CalledMe", "Welcome to CalledMe")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self, weak w] in
            w?.orderOut(nil)
            self?.showMainWindow()
            PermissionManager.shared.requestInitialPermissions()
        }))
        w.center()
        onboardingWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionBottomRight(_ window: NSWindow) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let f = window.frame
        window.setFrameOrigin(NSPoint(
            x: screen.maxX - f.width - 24,
            y: screen.minY + 24))
    }
}
