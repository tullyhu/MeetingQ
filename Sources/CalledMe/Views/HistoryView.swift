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
    @State private var selectedThemeId: Int64?
    @State private var showDeleteConfirm = false

    @MainActor public init(vm: HistoryViewModel? = nil) {
        _vm = State(initialValue: vm ?? HistoryViewModel())
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $vm.mode) {
                    ForEach(HistoryViewModel.Mode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if vm.mode == .meetings {
                    List(selection: $selectedId) {
                        ForEach(vm.sessions) { item in
                            SessionRow(item: item)
                                .tag(item.sessionId)
                        }
                    }
                    .listStyle(.sidebar)
                    .searchable(text: $vm.searchText, placement: .sidebar,
                                prompt: tr("搜索标题或议题", "Search title or topic"))
                } else {
                    List(selection: $selectedThemeId) {
                        ForEach(vm.themes.filter { !$0.archived }) { item in
                            ThemeRow(item: item)
                                .tag(item.id)
                        }
                        let archived = vm.themes.filter { $0.archived }
                        if !archived.isEmpty {
                            Section(tr("已归档", "Archived")) {
                                ForEach(archived) { item in
                                    ThemeRow(item: item)
                                        .tag(item.id)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationTitle(tr("历史会议", "History"))
            .safeAreaInset(edge: .bottom) {
                Text(vm.mode == .meetings ? vm.statusText : tr("共 \(vm.themes.count) 个主题", "\(vm.themes.count) themes"))
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
        .onChange(of: selectedThemeId) { _, newValue in
            vm.selectTheme(newValue)
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
        if vm.mode == .themes {
            if let themeId = selectedThemeId, let theme = vm.themes.first(where: { $0.id == themeId }) {
                ThemeDetailView(theme: theme, vm: vm)
                    .overlay(alignment: .topTrailing) {
                        if vm.isLoadingThemeDetail {
                            ProgressView().controlSize(.small).padding(12)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label(tr("主题聚合", "Themes"), systemImage: "square.stack.3d.up")
                } description: {
                    Text(tr("从左侧选择一个主题，查看跨会议聚合视图", "Select a theme to see cross-meeting aggregation"))
                }
            }
        } else if let session = vm.selectedSession {
            SessionDetailView(session: session, vm: vm, onDelete: { showDeleteConfirm = true })
                .overlay(alignment: .topTrailing) {
                    if vm.isLoadingDetail || vm.isRegenerating {
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

private struct ThemeRow: View {
    let item: ThemeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(tr("\(item.meetingCount) 次会议", "\(item.meetingCount) meetings"))
                if item.openActionCount > 0 {
                    Text("·")
                    Text(tr("\(item.openActionCount) 待办", "\(item.openActionCount) open"))
                        .foregroundStyle(.orange)
                }
                if let date = item.latestMeetingDate {
                    Text("·")
                    Text(HistoryFormatters.monthDay.string(from: date))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
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
                if let theme = item.themeName {
                    Text("·")
                    Text(theme)
                        .foregroundStyle(Color.accentColor)
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
            .mmSectionHeader()
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
                        Button(tr("会议纪要 (.md)", "Minutes (.md)")) { vm.exportMinutesMarkdown() }
                        Button(tr("会议纪要 (.html)", "Minutes (.html)")) { vm.exportMinutesHtml() }
                        Divider()
                        Button(tr("会议记录 (.md)", "Record (.md)")) { vm.exportRecordMarkdown() }
                        Button(tr("会议记录 (.html)", "Record (.html)")) { vm.exportRecordHtml() }
                        Divider()
                        Button(tr("纯文本 (.txt)", "Plain text (.txt)")) { vm.exportText() }
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
                    .padding(.bottom, 6)

                HStack(spacing: 8) {
                    if let typeName = session.meetingTypeName {
                        Label(typeName, systemImage: "tag")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    if let templateName = session.templateName {
                        Menu {
                            ForEach(MinutesTemplateLibrary.all, id: \.id) { t in
                                Button(t.name) { vm.regenerateMinutes(templateId: t.id) }
                            }
                        } label: {
                            Label(templateName, systemImage: "doc.text")
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.purple.opacity(0.12))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(tr("点击换模板重新生成纪要", "Switch template and regenerate minutes"))
                    }
                    if let score = session.qualityScore {
                        let color: Color = score >= 90 ? .green : (score >= 70 ? .orange : .red)
                        Label(tr("质量 \(score)", "Quality \(score)"), systemImage: "checkmark.seal")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(color.opacity(0.12))
                            .foregroundStyle(color)
                            .clipShape(Capsule())
                            .help(session.qualityIssues ?? tr("质量评估通过", "Quality check passed"))
                    }
                    Menu {
                        Button(tr("未归类", "No theme")) { vm.assignSessionToTheme(sessionId: session.sessionId, themeId: nil) }
                        Divider()
                        ForEach(vm.themes.filter { !$0.archived }) { t in
                            Button(t.name) { vm.assignSessionToTheme(sessionId: session.sessionId, themeId: t.id) }
                        }
                    } label: {
                        Label(session.themeName ?? tr("未归类", "No theme"), systemImage: "square.stack.3d.up")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.teal.opacity(0.12))
                            .foregroundStyle(.teal)
                            .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(tr("所属主题（点击改派）", "Theme (click to reassign)"))
                }
                .padding(.bottom, 14)

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
                        ForEach(session.decisions) { d in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let src = d.sourceLabel {
                                        Text(tr("来源 ", "Source ") + src)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
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
                    SectionHeader(title: tr("行动项（点击状态可切换）", "Action Items (click status to toggle)"))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(session.actionItems) { a in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    vm.cycleActionStatus(dbId: a.dbId, current: a.status)
                                } label: {
                                    Text(a.status == .complete ? "✅" : (a.deadline != nil && a.status != .complete ? "⏳" : "⏳"))
                                        .font(.callout)
                                }
                                .buttonStyle(.plain)
                                .help(tr("切换状态：待开始 → 进行中 → 已完成", "Toggle: not started → in progress → done"))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((a.priority.map { StructuredMinutes.priorityIcon($0) + " " } ?? "") + a.label)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .strikethrough(a.status == .complete)
                                        .foregroundStyle(a.status == .complete ? .secondary : .primary)
                                    Text(a.statusLabel + (a.sourceSpeaker.map { tr(" · 提出：", " · by: ") + $0 } ?? ""))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
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

private struct ThemeDetailView: View {
    let theme: ThemeItem
    let vm: HistoryViewModel
    @State private var editingName = false
    @State private var draftName = ""
    @State private var statusFilter: ActionItemStatus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if editingName {
                        TextField(tr("主题名称", "Theme name"), text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        Button(tr("保存", "Save")) {
                            vm.renameTheme(theme.id, to: draftName)
                            editingName = false
                        }
                        Button(tr("取消", "Cancel")) { editingName = false }
                    } else {
                        Text(theme.name)
                            .font(.title3.weight(.semibold))
                        Button {
                            draftName = theme.name
                            editingName = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(tr("重命名主题", "Rename theme"))
                    }
                    Spacer()
                    Menu {
                        ForEach(vm.themes.filter { !$0.archived && $0.id != theme.id }) { other in
                            Button(tr("合并到「\(other.name)」", "Merge into \"\(other.name)\"")) {
                                vm.mergeTheme(sourceId: theme.id, into: other.id)
                            }
                        }
                        if vm.themes.filter({ !$0.archived && $0.id != theme.id }).isEmpty {
                            Text(tr("（无其他主题可合并）", "(No other theme to merge)"))
                        }
                        Divider()
                        Button(theme.archived ? tr("取消归档", "Unarchive") : tr("归档", "Archive")) {
                            vm.setThemeArchived(theme.id, archived: !theme.archived)
                        }
                    } label: {
                        Label(tr("操作", "Actions"), systemImage: "ellipsis.circle")
                            .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                }
                .padding(.bottom, 6)

                if !theme.keywords.isEmpty {
                    Text(tr("关键词：", "Keywords: ") + theme.keywords.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }

                if let detail = vm.themeDetail {
                    let completed = detail.trackedActions.filter { $0.status == .complete }.count
                    HStack(spacing: 16) {
                        statBlock(tr("会议次数", "Meetings"), "\(detail.meetings.count)")
                        statBlock(tr("累计决策", "Decisions"), "\(detail.totalDecisions)")
                        statBlock(tr("累计行动项", "Actions"), "\(detail.trackedActions.count)")
                        statBlock(tr("已完成", "Done"), "\(completed)")
                    }
                    .padding(.vertical, 12)

                    SectionHeader(title: tr("会议时间线", "Meeting Timeline"))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.meetings) { m in
                            HStack(spacing: 10) {
                                Text(HistoryFormatters.monthDay.string(from: m.startTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(m.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text(tr("决策 \(m.decisionsCount)", "D \(m.decisionsCount)"))
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                Text(tr("行动 \(m.actionsCount)", "A \(m.actionsCount)"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.bottom, 20)

                    if !detail.trackedActions.isEmpty {
                        HStack {
                            SectionHeader(title: tr("跨会议行动项追踪", "Cross-meeting Action Tracking"))
                            Spacer()
                            Picker("", selection: $statusFilter) {
                                Text(tr("全部", "All")).tag(ActionItemStatus?.none)
                                Text(tr("待开始", "Not started")).tag(ActionItemStatus?.some(.notStarted))
                                Text(tr("进行中", "In progress")).tag(ActionItemStatus?.some(.inProgress))
                                Text(tr("已完成", "Done")).tag(ActionItemStatus?.some(.complete))
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 300)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(detail.trackedActions.filter { statusFilter == nil || $0.status == statusFilter }) { a in
                                HStack(alignment: .top, spacing: 8) {
                                    Button {
                                        vm.cycleActionStatus(dbId: a.dbId, current: a.status)
                                    } label: {
                                        Text(a.status == .complete ? "✅" : (a.isOverdue ? "🔴" : "⏳"))
                                    }
                                    .buttonStyle(.plain)
                                    .help(tr("切换状态", "Toggle status"))
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text((a.priority.map { StructuredMinutes.priorityIcon($0) + " " } ?? "") + a.task)
                                                .font(.callout)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .strikethrough(a.status == .complete)
                                            if a.mentionCount > 1 {
                                                Text(tr("第 \(a.mentionCount) 次提及", "×\(a.mentionCount)"))
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                                    .background(Color.orange.opacity(0.15))
                                                    .foregroundStyle(.orange)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text("\(a.owner)\(a.deadline.map { " · " + $0 } ?? "") · \(a.statusLabel) · \(HistoryFormatters.monthDay.string(from: a.sourceMeetingDate)) \(a.sourceMeetingTitle)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                } else if vm.isLoadingThemeDetail {
                    ProgressView()
                        .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        }
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
