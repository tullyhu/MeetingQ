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
public final class PopupManager: PopupManaging {
    public static let shared = PopupManager()

    public var onNameAlertAcknowledged: ((UUID) -> Void)?
    public var onQuickSummaryRefresh: (() -> Void)?

    private var alerts: [UUID: NSPanel] = [:]
    private var alertData: [UUID: NameAlertData] = [:]
    private var quickSummaryPanel: NSPanel?
    private let quickSummaryState = QuickSummaryState()
    private var albumPanel: NSPanel?

    private init() {}

    public func showNameAlert(_ data: NameAlertData) {
        for (id, existing) in alertData where !existing.isPinned {
            dismissNameAlert(id: id)
        }
        var d = data
        d.isPinned = false
        alertData[d.id] = d
        presentNameAlert(d)
    }

    public func dismissNameAlert(id: UUID) {
        guard let panel = alerts.removeValue(forKey: id) else {
            alertData.removeValue(forKey: id)
            return
        }
        alertData.removeValue(forKey: id)
        panel.close()
    }

    public func toggleNameAlertPin(id: UUID) {
        guard var d = alertData[id] else { return }
        d.isPinned.toggle()
        alertData[id] = d
        alerts.removeValue(forKey: id)?.close()
        presentNameAlert(d)
    }

    public func showQuickSummary(_ data: QuickSummaryData) {
        quickSummaryState.data = data
        if quickSummaryPanel == nil {
            let panel = makePanel(contentSize: NSSize(width: 480, height: 560))
            let view = QuickSummaryView(state: quickSummaryState,
                                        onRefresh: { [weak self] in self?.onQuickSummaryRefresh?() },
                                        onClose: { [weak self] in self?.dismissQuickSummary() })
            panel.contentView = NSHostingView(rootView: view)
            panel.center()
            quickSummaryPanel = panel
        }
        quickSummaryPanel?.orderFront(nil)
    }

    public func updateQuickSummary(_ data: QuickSummaryData) {
        guard quickSummaryPanel != nil else { return }
        quickSummaryState.data = data
    }

    public func dismissQuickSummary() {
        quickSummaryPanel?.close()
        quickSummaryPanel = nil
    }

    public func showScreenshotAlbum() {
        if let albumPanel {
            albumPanel.orderFront(nil)
            return
        }
        let session = currentSession()
        let vm = ScreenshotAlbumViewModel()
        vm.load(session: session)
        let panel = makePanel(contentSize: NSSize(width: 720, height: 520))
        panel.level = .normal
        let view = ScreenshotAlbumView(viewModel: vm, onClose: { [weak self] in
            self?.albumPanel?.close()
            self?.albumPanel = nil
        })
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.orderFront(nil)
        albumPanel = panel
    }

    public func dismissAll() {
        for id in Array(alerts.keys) { dismissNameAlert(id: id) }
        dismissQuickSummary()
        albumPanel?.close()
        albumPanel = nil
    }

    private func presentNameAlert(_ data: NameAlertData) {
        let view = NameAlertView(data: data, callbacks: NameAlertCallbacks(
            onAcknowledge: { [weak self] in
                self?.onNameAlertAcknowledged?(data.id)
                self?.dismissNameAlert(id: data.id)
            },
            onClose: { [weak self] in self?.dismissNameAlert(id: data.id) },
            onTogglePin: { [weak self] in self?.toggleNameAlertPin(id: data.id) }
        ))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 420, height: 10))
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = 420
        size.height = min(max(size.height, 120), 540)
        let panel = makePanel(contentSize: size)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        stackBottomRight(panel, excluding: data.id)
        panel.orderFront(nil)
        alerts[data.id] = panel
    }

    private func makePanel(contentSize: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func stackBottomRight(_ panel: NSPanel, excluding id: UUID? = nil) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let occupied = alerts.filter { $0.key != id }.values.reduce(CGFloat(0)) { $0 + $1.frame.height + 12 }
        var y = vf.minY + 16 + occupied
        y = min(y, vf.maxY - panel.frame.height - 8)
        y = max(y, vf.minY + 8)
        panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 16, y: y))
    }

    private func currentSession() -> MeetingSession? {
        DataStore.shared.latestMonitoringOrRecentSession()
    }
}
