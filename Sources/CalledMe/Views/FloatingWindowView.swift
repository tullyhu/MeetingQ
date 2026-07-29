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

public struct FloatingWindowView: View {
    @State private var vm: FloatingWindowViewModel
    @State private var topicFlash: Double = 0

    @MainActor public init(vm: FloatingWindowViewModel? = nil) {
        _vm = State(initialValue: vm ?? FloatingWindowViewModel())
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            statusStrip
            if !vm.isMonitoring { windowPicker }
            if vm.isDiagnosticVisible { diagnosticPanel }
            topicRow
            transcriptArea
            if vm.hasInlineSummary || vm.isInlineSummaryLoading { inlineSummary }
            bottomBar
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(mmHex: "E0E0E0"), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 14, x: 0, y: 6)
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 400,
               minHeight: 340, idealHeight: 440, maxHeight: 900)
        .onAppear { vm.refreshWindows() }
        .onReceive(NotificationCenter.default.publisher(for: .mmRunSelfTest)) { _ in
            Task { await vm.runSelfTest() }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isSelfTestRunning ? Color(mmHex: "818CF8")
                      : vm.isMonitoring ? Color(mmHex: "22C55E") : Color(mmHex: "CCCCCC"))
                .frame(width: 7, height: 7)
            Text("CalledMe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(mmHex: "111111"))
            Spacer()
            if vm.isMonitoring {
                iconButton("◉", tooltip: tr("自检状态", "Self Test Status")) { vm.toggleDiagnostics() }
            }
            iconButton("📋", tooltip: tr("历史会议", "Meeting History")) { WindowRouter.openHistory() }
            iconButton("⚙", tooltip: tr("设置", "Settings")) { WindowRouter.openSettings() }
            iconButton("▾", tooltip: tr("隐藏到托盘", "Hide to Menu Bar")) { WindowRouter.hideMainWindow() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .overlay(alignment: .bottom) { separator }
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.isMonitoring ? Color(mmHex: "22C55E") : Color(mmHex: "CCCCCC"))
                .frame(width: 6, height: 6)
            Text(vm.statusText)
                .font(.system(size: 11))
                .foregroundStyle(Color(mmHex: "555555"))
            Text("  ·  ")
                .font(.system(size: 11))
                .foregroundStyle(Color(mmHex: "DDDDDD"))
            Text(vm.elapsedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(mmHex: "888888"))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private var windowPicker: some View {
        HStack(spacing: 8) {
            Text(tr("截图窗口", "Capture Window"))
                .font(.system(size: 11))
                .foregroundStyle(Color(mmHex: "777777"))
            TextField(tr("选择会议窗口", "Select Meeting Window"), text: $vm.captureWindowTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color(mmHex: "111111"))
            Menu {
                ForEach(vm.availableWindows, id: \.self) { title in
                    Button(title) { vm.captureWindowTitle = title }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(mmHex: "555555"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            iconButton("↺", tooltip: tr("刷新窗口列表", "Refresh Window List"), size: 26, fontSize: 14) { vm.refreshWindows() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(mmHex: "F5F5F5"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(mmHex: "DDDDDD"), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var diagnosticPanel: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(mmHex: "6366F1"), Color(mmHex: "818CF8")],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(vm.diagnosticSteps) { step in
                            HStack(spacing: 0) {
                                Text(step.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(step.iconColor)
                                    .frame(width: 18, alignment: .leading)
                                Text(step.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(mmHex: "666666"))
                                    .frame(width: 68, alignment: .leading)
                                Text(step.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(step.detailColor)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)

                if vm.hasSelfTestResult {
                    Text(vm.selfTestResult)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(vm.selfTestPassed ? Color(mmHex: "228B22") : Color(mmHex: "CC3333"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(vm.selfTestPassed ? Color(mmHex: "EEFFEE") : Color(mmHex: "FFEEEE"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(vm.selfTestPassed ? Color(mmHex: "CCFFCC") : Color(mmHex: "FFCCCC"), lineWidth: 1))
                        .padding(.top, 6)
                }

                if vm.hasDiagnosticHint {
                    Text(vm.diagnosticHint)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(mmHex: "997700"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(mmHex: "FFFBEE"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(mmHex: "FFE580"), lineWidth: 1))
                        .padding(.top, 4)
                }
            }
            .padding(.leading, 10)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(Color(mmHex: "F5F5F5"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(mmHex: "DDDDDD"), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var topicRow: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(mmHex: "6366F1"))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("当前议题", "Current Topic"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(mmHex: "777777"))
                Text(vm.currentTopic)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(mmHex: "111111"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Color(mmHex: "E0E7FF").opacity(topicFlash))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: vm.topicFlashId) { _, _ in
            topicFlash = 1
            withAnimation(.easeOut(duration: 1.2)) { topicFlash = 0 }
        }
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(vm.latestTranscript)
                    .font(.system(size: 12))
                    .lineSpacing(10)
                    .foregroundStyle(Color(mmHex: "222222"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .id("transcriptBottom")
            }
            .onChange(of: vm.latestTranscript) { _, _ in
                withAnimation { proxy.scrollTo("transcriptBottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(mmHex: "F8F8F8"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(mmHex: "DDDDDD"), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var inlineSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("AI 摘要", "AI Summary"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(mmHex: "777777"))
                Spacer()
                if vm.isInlineSummaryLoading {
                    Text(tr("生成中…", "Generating…"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(mmHex: "AAAAAA"))
                }
            }
            ScrollView {
                Text(vm.inlineSummaryText)
                    .font(.system(size: 11))
                    .lineSpacing(7)
                    .foregroundStyle(Color(mmHex: "444444"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxHeight: 110)
        .background(Color(mmHex: "F0F0F0"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(mmHex: "DDDDDD"), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if vm.hasSessionData {
                ghostButton(tr("📷 截图", "📷 Screenshots"), color: Color(mmHex: "16A34A")) { vm.openScreenshotAlbum() }
            }
            ghostButton(vm.multimodalButtonText, color: Color(mmHex: "7C3AED")) { vm.toggleMultimodalMode() }
            if vm.hasSessionData {
                ghostButton(tr("⚡ 摘要", "⚡ Summary"), color: Color(mmHex: "2563EB")) { Task { await vm.showQuickSummary() } }
            }
            if vm.isMonitoring {
                ghostButton(vm.isManualAlertRunning ? tr("收集中…", "Collecting…") : tr("🔔 被叫到", "🔔 Name Called"),
                            color: vm.isManualAlertRunning ? Color(mmHex: "818CF8") : Color(mmHex: "D97706")) {
                    Task { await vm.manualTriggerAlert() }
                }
                .disabled(vm.isManualAlertRunning)
            } else {
                ghostButton(vm.isSelfTestRunning ? tr("自检中…", "Testing…") : tr("功能自检", "Self Test"),
                            color: vm.isSelfTestRunning ? Color(mmHex: "818CF8") : Color(mmHex: "555555")) {
                    Task { await vm.runSelfTest() }
                }
                .disabled(vm.isSelfTestRunning)
            }
            Button {
                Task {
                    if vm.isMonitoring { await vm.stopListening() } else { await vm.startListening() }
                }
            } label: {
                Text(vm.isMonitoring ? tr("停止监听", "Stop Listening") : tr("开始监听", "Start Listening"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(vm.isMonitoring ? Color(mmHex: "EF4444") : Color(mmHex: "6366F1"))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { separator }
    }

    private var separator: some View {
        LinearGradient(colors: [Color(mmHex: "E0E0E0").opacity(0), Color(mmHex: "E0E0E0"),
                                Color(mmHex: "E0E0E0"), Color(mmHex: "E0E0E0").opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
    }

    private func iconButton(_ symbol: String, tooltip: String, size: CGFloat = 28, fontSize: CGFloat = 13,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: fontSize))
                .foregroundStyle(Color(mmHex: "555555"))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func ghostButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(mmHex: "CCCCCC"), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
