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
        NavigationSplitView {
            List(selection: $selectedId) {
                ForEach(vm.sessions) { item in
                    SessionRow(item: item)
                        .tag(item.sessionId)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $vm.searchText, placement: .sidebar,
                        prompt: tr("搜索标题或议题", "Search title or topic"))
            .navigationTitle(tr("历史会议", "History"))
            .safeAreaInset(edge: .bottom) {
                Text(vm.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .frame(minWidth: 220)
        } detail: {
            detailPane
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { vm.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .mmSessionEnded)) { _ in vm.refresh() }
        .onChange(of: vm.searchText) { _, _ in vm.applyFilter() }
        .onChange(of: selectedId) { _, newValue in
            vm.selectSession(vm.sessions.first { $0.sessionId == newValue })
        }
        .onChange(of: vm.sessions.map(\.sessionId)) { _, _ in
            selectedId = vm.selectedSession?.sessionId
        }
        .confirmationDialog(tr("确定删除这条会议记录？相关截图文件将一并删除。",
                               "Delete this meeting record? Related screenshot files will also be deleted."),
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(tr("删除", "Delete"), role: .destructive) { vm.deleteSession() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let session = vm.selectedSession {
            SessionDetailView(session: session, vm: vm, onDelete: { showDeleteConfirm = true })
                .overlay(alignment: .topTrailing) {
                    if vm.isLoadingDetail {
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                    }
                }
        } else {
            ContentUnavailableView {
                Label(tr("历史会议", "Meeting History"), systemImage: "clock.arrow.circlepath")
            } description: {
                Text(tr("从左侧选择一条会议记录", "Select a meeting record from the sidebar"))
            }
        }
    }
}

private struct SessionRow: View {
    let item: SessionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(item.topicsLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(item.dateLabel)
                Text("·")
                Text(item.transcriptCountLabel)
                if item.hasScreenshots {
                    Image(systemName: "photo.on.rectangle")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }
}

private struct SessionDetailView: View {
    let session: SessionItem
    let vm: HistoryViewModel
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Spacer()
                    Menu {
                        Button(tr("会议纪要 (.md)", "Minutes (.md)")) { vm.exportMarkdown() }
                        Button(tr("会议纪要 (.html)", "Minutes (.html)")) { vm.exportHtml() }
                        Button(tr("转写记录 (.txt)", "Transcript (.txt)")) { vm.exportText() }
                    } label: {
                        Label(tr("导出", "Export"), systemImage: "square.and.arrow.up")
                            .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    Button(role: .destructive, action: onDelete) {
                        Label(tr("删除", "Delete"), systemImage: "trash")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
                Text(session.title)
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 4)
                Text("\(session.dateLabel)  ·  \(session.durationLabel)  ·  \(session.transcriptCountLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 18)

                SectionHeader(title: tr("议题", "Topics"))
                Text(session.topicsLabel)
                    .font(.callout)
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
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(session.decisions.enumerated()), id: \.offset) { _, d in
                            Label {
                                Text(d)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.bottom, 20)
                }

                if session.hasActionItems {
                    SectionHeader(title: tr("行动项", "Action Items"))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(session.actionItems) { a in
                            Label {
                                Text(a.label)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.bottom, 20)
                }

                if session.hasTranscripts {
                    SectionHeader(title: tr("转录记录", "Transcripts"))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.transcripts) { tr in
                            HStack(alignment: .top, spacing: 0) {
                                Text(tr.timeLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 56, alignment: .leading)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 0) {
                                    if let speaker = tr.speaker, !speaker.isEmpty {
                                        Text(speaker)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Text(tr.text)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else if vm.loadedIds.contains(session.sessionId) {
                    Text(tr("暂无转录记录", "No transcripts"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                } else if item.loadFailed {
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.tertiary)
                        )
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { HistoryLightbox.open(item) }
            .help(tr("点击放大", "Click to enlarge"))
            Text(item.timeLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
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
