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
    @State private var showTranscriptResetConfirm = false

    @MainActor public init(vm: FloatingWindowViewModel? = nil) {
        _vm = State(initialValue: vm ?? FloatingWindowViewModel())
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            statusStrip
            if !vm.isMonitoring { windowPicker }
            if vm.isDiagnosticVisible { diagnosticPanel }
            topicRow
            transcriptArea
            if vm.hasInlineSummary || vm.isInlineSummaryLoading { inlineSummary }
            Divider()
            bottomBar
        }
        .background(.regularMaterial)
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 440,
               minHeight: 380, idealHeight: 480, maxHeight: 900)
        .onAppear { vm.refreshWindows() }
        .onReceive(NotificationCenter.default.publisher(for: .mmRunSelfTest)) { _ in
            Task { await vm.runSelfTest() }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            StatusDot(isMonitoring: vm.isMonitoring, isSelfTestRunning: vm.isSelfTestRunning)
            Text("CalledMe")
                .font(.headline)
            Spacer()
            if vm.isMonitoring {
                headerButton("checklist", tooltip: tr("自检状态", "Self Test Status")) { vm.toggleDiagnostics() }
            }
            headerButton("clock.arrow.circlepath", tooltip: tr("历史会议", "Meeting History")) { WindowRouter.openHistory() }
            headerButton("gearshape", tooltip: tr("设置", "Settings")) { WindowRouter.openSettings() }
            headerButton("menubar.arrow.down.rectangle", tooltip: tr("隐藏到菜单栏", "Hide to Menu Bar")) { WindowRouter.hideMainWindow() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Label {
                Text(vm.statusText)
            } icon: {
                Image(systemName: vm.isMonitoring ? "waveform" : "waveform.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("·")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(vm.elapsedTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if vm.isMonitoring {
                AudioLevelMeter(segments: vm.audioLevelSegments)
                    .padding(.leading, 2)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var windowPicker: some View {
        HStack(spacing: 8) {
            Text(tr("截图窗口", "Capture Window"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: $vm.captureWindowTitle) {
                if vm.captureWindowTitle.isEmpty {
                    Text(tr("选择会议窗口", "Select Meeting Window")).tag("")
                }
                ForEach(vm.availableWindows, id: \.self) { title in
                    Text(title).tag(title)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            headerButton("arrow.clockwise", tooltip: tr("刷新窗口列表", "Refresh Window List")) { vm.refreshWindows() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var diagnosticPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(vm.diagnosticSteps) { step in
                        HStack(spacing: 8) {
                            Image(systemName: step.icon)
                                .font(.caption)
                                .foregroundStyle(step.iconColor)
                                .frame(width: 16, alignment: .leading)
                            Text(step.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(step.detail)
                                .font(.caption)
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
                Label(vm.selfTestResult, systemImage: vm.selfTestPassed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(vm.selfTestPassed ? Color.green : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if vm.hasDiagnosticHint {
                Label(vm.diagnosticHint, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .mmCard(padding: 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var topicRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("当前议题", "Current Topic"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(vm.currentTopic)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(topicFlash * 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: vm.topicFlashId) { _, _ in
            topicFlash = 1
            withAnimation(.easeOut(duration: 1.2)) { topicFlash = 0 }
        }
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.committedEntries) { entry in
                        TranscriptRow(entry: entry)
                            .transition(.opacity)
                    }
                    ForEach(vm.partialEntries) { entry in
                        TranscriptRow(entry: entry)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("transcriptBottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.committedEntries) { _, _ in
                withAnimation { proxy.scrollTo("transcriptBottom", anchor: .bottom) }
            }
            .onChange(of: vm.partialEntries) { _, _ in
                withAnimation { proxy.scrollTo("transcriptBottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: MMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MMRadius.card, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if !vm.committedEntries.isEmpty || !vm.partialEntries.isEmpty {
                Button { showTranscriptResetConfirm = true } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(tr("清空转写显示（不影响已保存的记录）", "Clear transcript display (saved records are not affected)"))
                .padding(4)
            }
        }
        .confirmationDialog(tr("确定清空当前转写显示？已保存的会议记录不受影响。",
                               "Clear the current transcript display? Saved meeting records are not affected."),
                            isPresented: $showTranscriptResetConfirm, titleVisibility: .visible) {
            Button(tr("清空", "Clear"), role: .destructive) { vm.resetTranscriptDisplay() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var inlineSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(tr("AI 摘要", "AI Summary"), systemImage: "sparkles")
                    .mmSectionHeader()
                Spacer()
                if vm.isInlineSummaryLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ScrollView {
                Text(vm.inlineSummaryText)
                    .font(.caption)
                    .lineSpacing(6)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxHeight: 110)
        .mmCard(padding: 0)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if vm.hasSessionData {
                bottomIcon("photo.on.rectangle", tooltip: tr("截图相册", "Screenshots")) { vm.openScreenshotAlbum() }
            }
            bottomIcon(vm.isMultimodalEnabled ? "eye" : "eye.slash",
                       tooltip: vm.isMultimodalEnabled ? tr("多模态分析已开启", "Multimodal analysis on")
                                                       : tr("多模态分析已关闭", "Multimodal analysis off")) {
                vm.toggleMultimodalMode()
            }
            if vm.hasSessionData {
                bottomIcon("doc.text", tooltip: tr("快速摘要", "Quick Summary")) { Task { await vm.showQuickSummary() } }
            }
            if vm.isMonitoring {
                bottomIcon("bell.badge",
                           tooltip: vm.isManualAlertRunning ? tr("收集中…", "Collecting…") : tr("模拟被叫到", "Simulate Name Call")) {
                    Task { await vm.manualTriggerAlert() }
                }
                .disabled(vm.isManualAlertRunning)
            } else {
                bottomIcon("checklist",
                           tooltip: vm.isSelfTestRunning ? tr("自检中…", "Testing…") : tr("自检", "Self Test")) {
                    Task { await vm.runSelfTest() }
                }
                .disabled(vm.isSelfTestRunning)
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    if vm.isMonitoring { await vm.stopListening() } else { await vm.startListening() }
                }
            } label: {
                Label(vm.isMonitoring ? tr("停止", "Stop") : tr("开始监听", "Start"),
                      systemImage: vm.isMonitoring ? "stop.circle.fill" : "record.circle")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isMonitoring ? .red : .accentColor)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func headerButton(_ symbol: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.mmIcon(size: 24))
        .help(tooltip)
    }

    private func bottomIcon(_ symbol: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.mmIcon(size: 30))
        .help(tooltip)
    }
}

private struct TranscriptRow: View {
    let entry: FloatingWindowViewModel.TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let speaker = entry.speaker {
                Text(speaker)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.isSelf ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(entry.isSelf ? Color.accentColor.opacity(0.12)
                                             : Color(nsColor: .separatorColor).opacity(0.35))
                    .clipShape(Capsule())
            }
            Text(entry.text)
                .font(.callout)
                .lineSpacing(4)
                .foregroundStyle(entry.isPartial ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatusDot: View {
    let isMonitoring: Bool
    let isSelfTestRunning: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(isSelfTestRunning ? Color.accentColor
                  : isMonitoring ? Color.green : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.35 : 1)
            .opacity(pulsing ? 0.6 : 1)
            .onAppear { updateAnimation() }
            .onChange(of: isMonitoring) { _, _ in updateAnimation() }
            .onChange(of: isSelfTestRunning) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if isMonitoring || isSelfTestRunning {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulsing = false }
        }
    }
}

private struct AudioLevelMeter: View {
    let segments: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < segments ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: 3, height: 5 + CGFloat(index) * 1.2)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: segments)
        .accessibilityLabel(tr("音量电平", "Audio level"))
    }
}
