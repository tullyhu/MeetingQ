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

@MainActor
public final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var menuLanguage: AppLanguage?

    public var onQuit: (() -> Void)?

    public init(icon: NSImage? = nil) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = icon ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "CalledMe")
        image?.isTemplate = true
        statusItem.button?.image = image
        buildMenu()
        NotificationCenter.default.addObserver(forName: .mmMonitoringStateChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.setMonitoring((note.object as? Bool) ?? false)
            }
        }
    }

    public func setMonitoring(_ isMonitoring: Bool) {
        let name = isMonitoring ? "record.circle.fill" : "waveform.circle.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "CalledMe")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem(tr("显示主窗口", "Show Main Window"), action: #selector(showMainWindow)))
        menu.addItem(makeItem(tr("历史会议…", "Meeting History…"), action: #selector(openHistory)))
        menu.addItem(makeItem(tr("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem(tr("退出 CalledMe", "Quit CalledMe"), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        menuLanguage = AppLanguage.current
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menuLanguage != AppLanguage.current {
            buildMenu()
        }
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func showMainWindow() {
        WindowRouter.showMainWindow()
    }

    @objc private func openHistory() {
        WindowRouter.openHistory()
    }

    @objc private func openSettings() {
        WindowRouter.openSettings()
    }


    @objc private func quit() {
        if let onQuit {
            onQuit()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}
