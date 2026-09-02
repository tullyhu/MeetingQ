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

@Observable
public final class QuickSummaryState {
    public var data = QuickSummaryData()

    public init() {}
}

public struct QuickSummaryView: View {
    public let state: QuickSummaryState
    public var onRefresh: () -> Void
    public var onClose: () -> Void

    public init(state: QuickSummaryState, onRefresh: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.state = state
        self.onRefresh = onRefresh
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                if state.data.isLoading {
                    skeleton
                } else {
                    content
                }
            }
            Divider()
            bottomBar
        }
        .frame(width: 480, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { onClose() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Label(tr("快速摘要", "Quick Summary"), systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Spacer()
            Text(tr("ESC 关闭", "ESC to Close"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(tr("AI 正在生成摘要…", "Generating summary…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            sectionHeader(tr("要点摘要", "Key Points"))
            Text(verbatim: "placeholder line one\nplaceholder line two\nplaceholder line three")
                .font(.callout)
                .lineSpacing(8)
                .redacted(reason: .placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(tr("当前议题", "Current Topic"))
            Text(state.data.topic)
                .font(.callout.weight(.medium))
                .padding(.bottom, 16)

            sectionHeader(tr("要点摘要", "Key Points"))
            Text(state.data.summary)
                .font(.callout)
                .lineSpacing(8)
                .padding(.bottom, 16)

            if !state.data.decisions.isEmpty {
                sectionHeader(tr("决策", "Decisions"))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(state.data.decisions.enumerated()), id: \.offset) { _, d in
                        Label {
                            Text(d)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .font(.callout)
                    }
                }
            }

            if !state.data.actionItems.isEmpty {
                sectionHeader(tr("行动项", "Action Items"))
                    .padding(.top, 16)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(state.data.actionItems.enumerated()), id: \.offset) { _, a in
                        Label {
                            Text(a)
                        } icon: {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .mmSectionHeader()
            .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: onRefresh) {
                Label(tr("刷新", "Refresh"), systemImage: "arrow.clockwise")
            }
            Button(action: copySummary) {
                Label(tr("复制摘要", "Copy"), systemImage: "doc.on.doc")
            }
            Spacer()
            Button(tr("关闭", "Close"), action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func copySummary() {
        let text = tr("会议纪要 — \(state.data.topic)\n\n\(state.data.summary)",
                      "Meeting Minutes — \(state.data.topic)\n\n\(state.data.summary)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
