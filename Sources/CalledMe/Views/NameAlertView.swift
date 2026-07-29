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
import AppKit

public struct NameAlertCallbacks {
    public var onAcknowledge: () -> Void
    public var onClose: () -> Void
    public var onTogglePin: () -> Void

    public init(onAcknowledge: @escaping () -> Void, onClose: @escaping () -> Void, onTogglePin: @escaping () -> Void) {
        self.onAcknowledge = onAcknowledge
        self.onClose = onClose
        self.onTogglePin = onTogglePin
    }
}

public struct NameAlertView: View {
    public let data: NameAlertData
    public let callbacks: NameAlertCallbacks

    @State private var screenshot: NSImage?

    private static let headerBg = Color(red: 1, green: 0.953, blue: 0.804)
    private static let accent = Color(red: 0.706, green: 0.325, blue: 0.035)
    private static let buttonBg = Color(red: 1, green: 0.702, blue: 0.278)

    public init(data: NameAlertData, callbacks: NameAlertCallbacks) {
        self.data = data
        self.callbacks = callbacks
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    screenshotSection
                    quoteSection
                    questionsSection
                    contextSection
                    HStack {
                        Spacer()
                        Button(action: callbacks.onAcknowledge) {
                            Text(tr("✅ 我知道了", "✅ Got It"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(white: 0.07))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 7)
                                .background(Self.buttonBg)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 12)
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
            }
            .frame(maxHeight: 480)
        }
        .frame(width: 420)
        .background(Color(red: 0.973, green: 0.973, blue: 0.973))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 1, green: 0.702, blue: 0.278).opacity(0.38), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 5)
        .onAppear { loadScreenshot() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("⚠️").font(.system(size: 14))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.accent)
            }
            Spacer()
            Button(action: callbacks.onTogglePin) {
                Text("📌")
                    .font(.system(size: 13))
                    .opacity(data.isPinned ? 1.0 : 0.4)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(data.isPinned ? tr("已固定 — 点击取消固定", "Pinned — click to unpin") : tr("固定此提示（防止被新提醒覆盖）", "Pin this alert (prevents it from being replaced by new alerts)"))
            Button(action: callbacks.onClose) {
                Text("✕")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.47))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Self.headerBg)
    }

    @ViewBuilder
    private var screenshotSection: some View {
        if let screenshot {
            Text(tr("📸  被叫时截图", "📸  Screenshot When Called"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.accent)
                .padding(.bottom, 5)
            Image(nsImage: screenshot)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: 160)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { Lightbox.show(image: screenshot) }
                .help(tr("点击放大查看", "Click to enlarge"))
                .padding(.bottom, 12)
        }
    }

    private var quoteSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("原话", "Quote"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.accent)
                .padding(.bottom, 5)
            Text(data.quote)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.07))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Self.headerBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
        }
    }

    private var questionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("📍 需要你回答的问题", "📍 Questions for You"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.accent)
                .padding(.bottom, 5)
            ForEach(Array(data.questions.enumerated()), id: \.offset) { index, q in
                Text("\(numberedCircle(index))  \(q)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.07))
                    .padding(.vertical, 2)
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var contextSection: some View {
        if !data.context.isEmpty {
            Rectangle()
                .fill(Color(white: 0.87).opacity(0.6))
                .frame(height: 1)
                .padding(.bottom, 10)
            Text(tr("📋 前后上下文（最近1分钟）", "📋 Surrounding Context (last minute)"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(white: 0.47))
                .padding(.bottom, 5)
            ForEach(Array(data.context.enumerated()), id: \.offset) { _, line in
                Text(contextText(line))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.vertical, 1)
            }
        }
    }

    private func contextText(_ line: TranscriptContextLine) -> String {
        if let speaker = line.speaker, !speaker.isEmpty {
            return "\(line.time) \(speaker): \(line.text)"
        }
        return "\(line.time) \(line.text)"
    }

    private func elapsedText(at now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(data.detectedAt)))
        if AppLanguage.current.isEnglish {
            return s < 60 ? "You were called \(s)s ago!" : "You were called \(s / 60)m \(s % 60)s ago!"
        }
        return s < 60 ? "\(s)秒前有人叫你！" : "\(s / 60)分\(s % 60)秒前有人叫你！"
    }

    private func numberedCircle(_ index: Int) -> String {
        switch index {
        case 0: return "❶"
        case 1: return "❷"
        case 2: return "❸"
        case 3: return "❹"
        case 4: return "❺"
        case 5: return "❻"
        case 6: return "❼"
        case 7: return "❽"
        case 8: return "❾"
        default: return "\(index + 1)."
        }
    }

    private func loadScreenshot() {
        guard let path = data.screenshotPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        screenshot = NSImage(contentsOfFile: path)
    }
}

private final class LightboxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

private struct LightboxView: View {
    let image: NSImage
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.86)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onExitCommand { onClose() }
    }
}

public enum Lightbox {
    @MainActor
    public static func show(image: NSImage) {
        guard let screen = NSScreen.main else { return }
        let panel = LightboxPanel(contentRect: screen.frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        var panelRef: NSPanel? = panel
        let view = LightboxView(image: image) {
            panelRef?.close()
            panelRef = nil
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFront(nil)
        panel.makeKey()
    }
}
