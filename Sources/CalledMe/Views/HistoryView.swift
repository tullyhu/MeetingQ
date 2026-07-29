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

public struct HistoryView: View {
    @State private var vm: HistoryViewModel
    @State private var selectedId: Int64?
    @State private var showDeleteConfirm = false

    @MainActor public init(vm: HistoryViewModel? = nil) {
        _vm = State(initialValue: vm ?? HistoryViewModel())
    }

    public var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 540)
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { vm.refresh() }
        .onChange(of: vm.searchText) { _, _ in vm.applyFilter() }
        .confirmationDialog(tr("确定删除这条会议记录？相关截图文件将一并删除。",
                               "Delete this meeting record? Related screenshot files will also be deleted."),
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(tr("删除", "Delete"), role: .destructive) { vm.deleteSession() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        }
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("🗂").font(.system(size: 14))
                Text(tr("历史会议", "Meeting History"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.39, green: 0.40, blue: 0.95))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Divider()

            TextField(tr("搜索标题或议题关键词", "Search title or topic keywords"), text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            Divider()

            List(selection: $selectedId) {
                ForEach(vm.sessions) { item in
                    SessionRow(item: item)
                        .tag(item.sessionId)
                }
            }
            .listStyle(.plain)
            .onChange(of: selectedId) { _, newValue in
                vm.selectSession(vm.sessions.first { $0.sessionId == newValue })
            }
            .onChange(of: vm.sessions.map(\.sessionId)) { _, _ in
                selectedId = vm.selectedSession?.sessionId
            }

            Divider()
            Text(vm.statusText)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.67))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 36)
        }
        .background(Color(white: 0.96))
    }

    private var rightPane: some View {
        ZStack(alignment: .topTrailing) {
            if let session = vm.selectedSession {
                VStack(spacing: 0) {
                    SessionDetailView(session: session, vm: vm)
                    Divider()
                    bottomBar
                }
            } else {
                VStack(spacing: 10) {
                    Text("📂").font(.system(size: 32))
                    Text(tr("选择一条会议记录", "Select a meeting record"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.67))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if vm.isLoadingDetail {
                Text(tr("加载中...", "Loading..."))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.39, green: 0.40, blue: 0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.93, green: 0.95, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            ActionButton(title: tr("导出会议纪要 (.md)", "Export Minutes (.md)"),
                         bg: Color(red: 0.93, green: 0.95, blue: 1.0),
                         fg: Color(red: 0.39, green: 0.40, blue: 0.95)) {
                vm.exportMarkdown()
            }
            ActionButton(title: tr("导出会议纪要 (.html)", "Export Minutes (.html)"),
                         bg: Color(red: 1.0, green: 0.97, blue: 0.93),
                         fg: Color(red: 0.92, green: 0.35, blue: 0.05)) {
                vm.exportHtml()
            }
            ActionButton(title: tr("导出转写记录 (.txt)", "Export Transcript (.txt)"),
                         bg: Color(red: 0.94, green: 0.99, blue: 0.96),
                         fg: Color(red: 0.09, green: 0.64, blue: 0.29)) {
                vm.exportText()
            }
            Spacer()
            ActionButton(title: tr("删除此记录", "Delete This Record"),
                         bg: Color(red: 1.0, green: 0.96, blue: 0.96),
                         fg: Color(red: 0.94, green: 0.27, blue: 0.27)) {
                showDeleteConfirm = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.96))
    }
}

private struct ActionButton: View {
    let title: String
    let bg: Color
    let fg: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(fg.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let item: SessionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.07))
                .lineLimit(1)
            Text(item.topicsLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.53))
                .lineLimit(2)
            HStack(spacing: 0) {
                Text(item.transcriptCountLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.67))
                if item.hasScreenshots {
                    Text("  ·  ")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.87))
                    Text("📷")
                        .font(.system(size: 9))
                }
            }
            Text(item.dateLabel)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.67))
        }
        .padding(.vertical, 4)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(white: 0.53))
            .padding(.bottom, 6)
    }
}

private struct SessionDetailView: View {
    let session: SessionItem
    let vm: HistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(white: 0.07))
                    .padding(.bottom, 4)
                Text("\(session.dateLabel)  ·  \(session.durationLabel)  ·  \(session.transcriptCountLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.53))
                    .padding(.bottom, 18)

                SectionHeader(title: tr("议题", "Topics"))
                Text(session.topicsLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.33))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 20)

                if session.hasScreenshots {
                    SectionHeader(title: tr("截图", "Screenshots"))
                    FlowLayout(spacing: 8) {
                        ForEach(session.screenshotPaths) { shot in
                            ScreenshotThumb(item: shot)
                        }
                    }
                    .padding(.bottom, 20)
                }

                if session.hasDecisions {
                    SectionHeader(title: tr("决策", "Decisions"))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(session.decisions.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .top, spacing: 0) {
                                Text("• ")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0.09, green: 0.64, blue: 0.29))
                                Text(d)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(white: 0.2))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }

                if session.hasActionItems {
                    SectionHeader(title: tr("行动项", "Action Items"))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.actionItems) { a in
                            HStack(alignment: .top, spacing: 0) {
                                Text("→ ")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.02))
                                Text(a.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(white: 0.2))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }

                if session.hasTranscripts {
                    SectionHeader(title: tr("转录记录", "Transcripts"))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.transcripts) { tr in
                            HStack(alignment: .top, spacing: 0) {
                                Text(tr.timeLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.67))
                                    .frame(width: 56, alignment: .leading)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 0) {
                                    if let speaker = tr.speaker, !speaker.isEmpty {
                                        Text(speaker)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color(red: 0.39, green: 0.40, blue: 0.95))
                                    }
                                    Text(tr.text)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(white: 0.2))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else if vm.loadedIds.contains(session.sessionId) {
                    Text(tr("暂无转录记录", "No transcripts"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.67))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        }
    }
}

private struct ScreenshotThumb: View {
    let item: ScreenshotItem

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(white: 0.92))
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { HistoryLightbox.open(item) }
            .help(tr("点击放大", "Click to enlarge"))
            Text(item.timeLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(white: 0.67))
        }
        .task { await item.loadThumbnail() }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                maxWidth = max(maxWidth, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        maxWidth = max(maxWidth, x - spacing)
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

@MainActor private enum HistoryLightbox {
    private static var windows: [NSWindow] = []

    static func open(_ item: ScreenshotItem) {
        guard let image = NSImage(contentsOfFile: item.filePath) else {
            return
        }
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        var size = image.size
        let maxW = screen.width * 0.85
        let maxH = screen.height * 0.85
        if size.width > maxW || size.height > maxH {
            let scale = min(maxW / size.width, maxH / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = tr("\(item.timeLabel) 截图", "\(item.timeLabel) Screenshot")
        window.isReleasedWhenClosed = false
        let imageView = NSImageView(frame: rect)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { note in
            if let w = note.object as? NSWindow {
                windows.removeAll { $0 === w }
            }
        }
    }
}
