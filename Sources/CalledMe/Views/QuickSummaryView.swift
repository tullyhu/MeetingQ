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

    @State private var pulse = false

    private static let accent = Color(red: 0.145, green: 0.388, blue: 0.922)

    public init(state: QuickSummaryState, onRefresh: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.state = state
        self.onRefresh = onRefresh
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                if state.data.isLoading {
                    skeleton
                } else {
                    content
                }
            }
            bottomBar
        }
        .frame(width: 480, height: 560)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.87), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 24, y: 6)
        .onExitCommand { onClose() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("⚡").font(.system(size: 16))
            Text(tr("快速摘要", "Quick Summary"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(white: 0.07))
            Spacer()
            Text(tr("ESC 关闭", "ESC to Close"))
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.67))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(white: 0.96))
    }

    private var skeleton: some View {
        VStack(spacing: 0) {
            Text(tr("加载中...", "Loading..."))
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.67))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            skeletonLine(width: nil)
            skeletonLine(width: 340)
            skeletonLine(width: 280)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { pulse = true }
    }

    private func skeletonLine(width: CGFloat?) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(white: 0.93))
            .frame(width: width, height: 12)
            .frame(maxWidth: .infinity, alignment: width == nil ? .center : .leading)
            .opacity(pulse ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .padding(.vertical, 6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(tr("当前议题", "Current Topic"))
            Text(state.data.topic)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(white: 0.07))
                .padding(.bottom, 16)

            sectionHeader(tr("要点摘要", "Key Points"))
            Text(state.data.summary)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.13))
                .lineSpacing(8)
                .padding(.bottom, 16)

            if !state.data.decisions.isEmpty {
                sectionHeader(tr("决策", "Decisions"))
                ForEach(Array(state.data.decisions.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•").foregroundStyle(Color(red: 0.086, green: 0.639, blue: 0.29))
                        Text(d).foregroundStyle(Color(white: 0.13))
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 3)
                }
            }

            if !state.data.actionItems.isEmpty {
                sectionHeader(tr("行动项", "Action Items"))
                    .padding(.top, 16)
                ForEach(Array(state.data.actionItems.enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .top, spacing: 4) {
                        Text("→").foregroundStyle(Color(red: 0.851, green: 0.467, blue: 0.024))
                        Text(a).foregroundStyle(Color(white: 0.13))
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.accent)
            .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: onRefresh) {
                Text(tr("🔄 刷新", "🔄 Refresh"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.388, green: 0.4, blue: 0.945))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.933, green: 0.949, blue: 1))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.78, green: 0.824, blue: 1), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Button(action: copySummary) {
                Text(tr("📋 复制摘要", "📋 Copy Summary"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.33))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.96))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.87), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: onClose) {
                Text(tr("关闭", "Close"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.2))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.87))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.94))
    }

    private func copySummary() {
        let text = tr("会议纪要 — \(state.data.topic)\n\n\(state.data.summary)",
                      "Meeting Minutes — \(state.data.topic)\n\n\(state.data.summary)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
