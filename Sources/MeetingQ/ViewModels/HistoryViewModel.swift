// MeetingQ - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 MeetingQ contributors
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

import Foundation
import AppKit
import UniformTypeIdentifiers

public struct TranscriptItem: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let speaker: String?
    public let text: String

    public var timeLabel: String {
        HistoryFormatters.timeLabel.string(from: timestamp)
    }
}

public struct ActionItemDisplay: Sendable, Identifiable {
    public let id = UUID()
    public let dbId: Int64
    public let assignedTo: String
    public let task: String
    public let deadline: String?
    public let priority: String?
    public let status: ActionItemStatus
    public let sourceSpeaker: String?
    public let timestamp: Date

    public var label: String {
        guard let deadline, !deadline.isEmpty else { return tr("\(assignedTo)：\(task)", "\(assignedTo): \(task)") }
        return tr("\(assignedTo)：\(task)（\(deadline)）", "\(assignedTo): \(task) (\(deadline))")
    }

    public var statusLabel: String {
        let item = ActionItem(timestamp: timestamp, assignedTo: assignedTo, task: task, deadline: deadline)
        item.statusRaw = status.rawValue
        return MinutesRenderer.statusLabel(item)
    }
}

public struct DecisionDisplay: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let timestamp: Date
    public let sourceSpeaker: String?

    public var sourceLabel: String? {
        guard let speaker = sourceSpeaker, !speaker.isEmpty else { return nil }
        return "[\(HistoryFormatters.timeLabel.string(from: timestamp))] \(speaker)"
    }
}

@MainActor @Observable
public final class ScreenshotItem: Identifiable {
    public let filePath: String
    public let timestamp: Date
    public var aiSummary: String?
    public var analysisStatus: String?
    public var activeSpeakerName: String?
    public var thumbnail: NSImage?
    public private(set) var loadFailed = false

    public var id: String { filePath }

    public var timeLabel: String {
        HistoryFormatters.timeLabel.string(from: timestamp)
    }

    public init(filePath: String, timestamp: Date, aiSummary: String? = nil,
                analysisStatus: String? = nil, activeSpeakerName: String? = nil) {
        self.filePath = filePath
        self.timestamp = timestamp
        self.aiSummary = aiSummary
        self.analysisStatus = analysisStatus
        self.activeSpeakerName = activeSpeakerName
    }

    public func loadThumbnail() async {
        guard thumbnail == nil, !loadFailed else { return }
        let path = filePath
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = NSImage(contentsOfFile: path) else { return nil }
            let width: CGFloat = 320
            let scale = src.size.width > 0 ? width / src.size.width : 1
            let size = NSSize(width: width, height: max(1, src.size.height * scale))
            let img = NSImage(size: size)
            img.lockFocus()
            src.draw(in: NSRect(origin: .zero, size: size),
                     from: NSRect(origin: .zero, size: src.size),
                     operation: .sourceOver, fraction: 1)
            img.unlockFocus()
            return img
        }.value
        if thumbnail == nil {
            if let image {
                thumbnail = image
            } else {
                loadFailed = true
            }
        }
    }
}

@MainActor @Observable
public final class SessionItem: Identifiable {
    public let sessionId: Int64
    public let title: String
    public let startTime: Date
    public let endTime: Date?
    public var overallSummary: String?
    public var transcriptCount: Int
    public let screenshotCount: Int
    public let topicTitles: [String]
    public var topicSummaries: [String] = []
    public var transcripts: [TranscriptItem] = []
    public var screenshotPaths: [ScreenshotItem]
    public var decisions: [DecisionDisplay] = []
    public var actionItems: [ActionItemDisplay] = []
    public var templateId: String?
    public var meetingType: String?
    public var qualityScore: Int?
    public var qualityIssues: String?
    public var themeId: Int64?
    public var themeName: String?

    public var id: Int64 { sessionId }

    public var templateName: String? { MinutesTemplateLibrary.displayName(for: templateId) }
    public var meetingTypeName: String? { meetingType.map { TemplateRecommender.meetingTypeName($0) } }

    public var dateLabel: String {
        HistoryFormatters.dateLabel.string(from: startTime)
    }

    public var durationLabel: String {
        guard let endTime else { return "—" }
        let d = max(0, endTime.timeIntervalSince(startTime))
        let total = Int(d)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours >= 1 ? "\(hours)h \(minutes)m" : "\(minutes)m \(seconds)s"
    }

    public var topicsLabel: String {
        topicTitles.isEmpty ? tr("（无议题）", "(No topics)") : topicTitles.joined(separator: "  ·  ")
    }

    public var transcriptCountLabel: String { tr("\(transcriptCount) 条转录", "\(transcriptCount) transcripts") }
    public var hasTranscripts: Bool { !transcripts.isEmpty }
    public var hasScreenshots: Bool { !screenshotPaths.isEmpty }
    public var hasDecisions: Bool { !decisions.isEmpty }
    public var hasActionItems: Bool { !actionItems.isEmpty }

    public init(sessionId: Int64, title: String, startTime: Date, endTime: Date?,
                overallSummary: String?, transcriptCount: Int, screenshotCount: Int,
                topicTitles: [String], screenshotPaths: [ScreenshotItem],
                templateId: String? = nil, meetingType: String? = nil,
                qualityScore: Int? = nil, themeId: Int64? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.overallSummary = overallSummary
        self.transcriptCount = transcriptCount
        self.screenshotCount = screenshotCount
        self.topicTitles = topicTitles
        self.screenshotPaths = screenshotPaths
        self.templateId = templateId
        self.meetingType = meetingType
        self.qualityScore = qualityScore
        self.themeId = themeId
    }
}

public struct ThemeItem: Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let keywords: [String]
    public let archived: Bool
    public var meetingCount: Int = 0
    public var openActionCount: Int = 0
    public var latestMeetingDate: Date?
}

public struct ThemeMeetingEntry: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let startTime: Date
    public let decisionsCount: Int
    public let actionsCount: Int
}

public struct ThemeDetail: Sendable {
    public var meetings: [ThemeMeetingEntry] = []
    public var totalDecisions: Int = 0
    public var trackedActions: [TrackedActionDisplay] = []
}

public struct TrackedActionDisplay: Identifiable, Sendable {
    public let id = UUID()
    public let dbId: Int64
    public let task: String
    public let owner: String
    public let deadline: String?
    public let priority: String?
    public let status: ActionItemStatus
    public let isOverdue: Bool
    public let mentionCount: Int
    public let sourceMeetingTitle: String
    public let sourceMeetingDate: Date

    public var statusLabel: String {
        let item = ActionItem(timestamp: sourceMeetingDate, assignedTo: owner, task: task, deadline: deadline)
        item.statusRaw = status.rawValue
        return MinutesRenderer.statusLabel(item)
    }
}

enum HistoryFormatters {
    static let dateLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = tr("yyyy年MM月dd日  HH:mm", "yyyy-MM-dd  HH:mm"); return f
    }()
    static let exportDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = tr("yyyy年MM月dd日 HH:mm", "yyyy-MM-dd HH:mm"); return f
    }()
    static let timeLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let shotStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; return f
    }()
    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmm"; return f
    }()
    static let footer: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
}

private struct ShotSnapshot: Sendable {
    let filePath: String
    let timestamp: Date
    let aiSummary: String?
    let analysisStatus: String?
    let activeSpeakerName: String?
}

private struct SessionSnapshot: Sendable {
    let id: Int64
    let title: String
    let startTime: Date
    let endTime: Date?
    let summary: String?
    let transcriptCount: Int
    let screenshotCount: Int
    let topicTitles: [String]
    let screenshots: [ShotSnapshot]
    let templateId: String?
    let meetingType: String?
    let qualityScore: Int?
    let themeId: Int64?
}

private struct DetailSnapshot: Sendable {
    let topicSummaries: [String]
    let transcripts: [TranscriptItem]
    let decisions: [DecisionDisplay]
    let actionItems: [ActionItemDisplay]
    let screenshots: [ShotSnapshot]
    let summary: String?
}

@MainActor @Observable
public final class HistoryViewModel {
    public private(set) var sessions: [SessionItem] = []
    public private(set) var allSessions: [SessionItem] = []
    public private(set) var selectedSession: SessionItem?
    public var searchText = ""
    public var mode: Mode = .meetings
    public private(set) var themes: [ThemeItem] = []
    public private(set) var selectedThemeId: Int64?
    public private(set) var themeDetail: ThemeDetail?
    public private(set) var isLoadingThemeDetail = false
    public private(set) var statusText = tr("加载历史会议...", "Loading meeting history...")
    public private(set) var isLoading = true
    public private(set) var isLoadingDetail = false
    public private(set) var loadedIds: Set<Int64> = []

    public enum Mode: String, CaseIterable {
        case meetings, themes
        public var label: String {
            switch self {
            case .meetings: return tr("会议", "Meetings")
            case .themes: return tr("主题", "Themes")
            }
        }
    }

    public var hasSelected: Bool { selectedSession != nil }
    public var filteredCount: Int { sessions.count }
    public var totalCount: Int { allSessions.count }

    private var detailTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?

    public init() {}

    public func refresh() {
        selectedSession = nil
        loadList()
        loadThemes()
    }

    private func loadList() {
        isLoading = true
        statusText = tr("加载历史会议...", "Loading meeting history...")
        detailTask?.cancel()
        sessions = []
        allSessions = []
        loadedIds = []
        listTask?.cancel()
        listTask = Task {
            let snaps = await Self.fetchSessionList()
            guard !Task.isCancelled else { return }
            applyList(snaps)
            statusText = snaps.isEmpty ? tr("暂无历史会议", "No meeting history") : tr("共 \(snaps.count) 次会议", "\(snaps.count) meetings")
            isLoading = false
        }
    }

    private func applyList(_ snaps: [SessionSnapshot]) {
        let themeNames = Dictionary(uniqueKeysWithValues: DataStore.shared.fetchThemes().map { ($0.id, $0.name) })
        allSessions = snaps.map { s in
            let item = SessionItem(
                sessionId: s.id,
                title: s.title,
                startTime: s.startTime,
                endTime: s.endTime,
                overallSummary: s.summary,
                transcriptCount: s.transcriptCount,
                screenshotCount: s.screenshotCount,
                topicTitles: s.topicTitles,
                screenshotPaths: s.screenshots.map {
                    ScreenshotItem(filePath: $0.filePath, timestamp: $0.timestamp,
                                   aiSummary: $0.aiSummary, analysisStatus: $0.analysisStatus,
                                   activeSpeakerName: $0.activeSpeakerName)
                },
                templateId: s.templateId,
                meetingType: s.meetingType,
                qualityScore: s.qualityScore,
                themeId: s.themeId)
            item.themeName = s.themeId.flatMap { themeNames[$0] }
            return item
        }
        applyFilter()
    }

    public func applyFilter() {
        let selected = selectedSession
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            sessions = allSessions
        } else {
            sessions = allSessions.filter { s in
                s.title.range(of: query, options: .caseInsensitive) != nil ||
                s.topicTitles.contains { $0.range(of: query, options: .caseInsensitive) != nil }
            }
        }
        if let selected, !sessions.contains(where: { $0.sessionId == selected.sessionId }) {
            selectedSession = nil
        }
        statusText = query.isEmpty
            ? tr("共 \(allSessions.count) 次会议", "\(allSessions.count) meetings")
            : tr("筛选：\(sessions.count) / \(allSessions.count) 次", "Filtered: \(sessions.count) / \(allSessions.count)")
    }

    public func selectSession(_ item: SessionItem?) {
        selectedSession = item
        detailTask?.cancel()
        detailTask = nil
        guard let item, !loadedIds.contains(item.sessionId) else { return }
        loadDetail(item.sessionId)
    }

    private func loadDetail(_ sessionId: Int64) {
        isLoadingDetail = true
        detailTask = Task {
            if let snap = await Self.fetchDetail(id: sessionId) {
                guard !Task.isCancelled else { return }
                applyDetail(snap, to: sessionId)
            } else {
                guard !Task.isCancelled else { return }
            }
            isLoadingDetail = false
        }
    }

    private func applyDetail(_ snap: DetailSnapshot, to sessionId: Int64) {
        guard let target = allSessions.first(where: { $0.sessionId == sessionId }) else { return }
        target.topicSummaries = snap.topicSummaries
        target.transcripts = snap.transcripts
        target.decisions = snap.decisions
        target.actionItems = snap.actionItems
        target.transcriptCount = snap.transcripts.count
        let existing = Dictionary(target.screenshotPaths.map { ($0.filePath, $0) },
                                  uniquingKeysWith: { first, _ in first })
        target.screenshotPaths = snap.screenshots.map { s in
            if let item = existing[s.filePath] {
                item.aiSummary = s.aiSummary
                item.analysisStatus = s.analysisStatus
                item.activeSpeakerName = s.activeSpeakerName
                return item
            }
            return ScreenshotItem(filePath: s.filePath, timestamp: s.timestamp,
                                  aiSummary: s.aiSummary, analysisStatus: s.analysisStatus,
                                  activeSpeakerName: s.activeSpeakerName)
        }
        target.overallSummary = snap.summary
        loadedIds.insert(sessionId)
    }

    private func ensureDetailLoaded(_ session: SessionItem) async {
        guard !loadedIds.contains(session.sessionId) else { return }
        guard let snap = await Self.fetchDetail(id: session.sessionId) else {
            return
        }
        applyDetail(snap, to: session.sessionId)
    }

    public func deleteSession() {
        guard let selected = selectedSession else { return }
        let id = selected.sessionId
        let filePaths = DataStore.shared.deleteSession(id: id)
        for path in filePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        allSessions.removeAll { $0.sessionId == id }
        loadedIds.remove(id)
        selectedSession = nil
        applyFilter()
        statusText = tr("已删除", "Deleted")
    }

    // MARK: - Themes

    public func loadThemes() {
        Task {
            let items = await Task.detached(priority: .userInitiated) { () -> [ThemeItem] in
                let store = DataStore.shared
                return store.fetchThemes().map { theme in
                    var item = ThemeItem(id: theme.id, name: theme.name, keywords: theme.keywords, archived: theme.archived)
                    let sessions = store.fetchSessions(themeId: theme.id)
                    item.meetingCount = sessions.count
                    item.latestMeetingDate = sessions.first?.startTime
                    var open = 0
                    for s in sessions {
                        for t in store.fetchTopics(sessionId: s.id) {
                            for a in store.fetchActionItems(topicId: t.id) where a.status != .complete {
                                open += 1
                            }
                        }
                    }
                    item.openActionCount = open
                    return item
                }
            }.value
            themes = items
        }
    }

    public func selectTheme(_ id: Int64?) {
        selectedThemeId = id
        themeDetail = nil
        guard let id else { return }
        isLoadingThemeDetail = true
        Task {
            let detail = await Task.detached(priority: .userInitiated) { () -> ThemeDetail? in
                let store = DataStore.shared
                let sessions = store.fetchSessions(themeId: id).sorted { $0.startTime < $1.startTime }
                var d = ThemeDetail()
                var allActions: [ActionItem] = []
                var actionMeeting: [Int64: (title: String, date: Date)] = [:]
                for s in sessions {
                    let topics = store.fetchTopics(sessionId: s.id)
                    var dc = 0
                    var ac = 0
                    for t in topics {
                        dc += store.fetchDecisions(topicId: t.id).count
                        let acts = store.fetchActionItems(topicId: t.id)
                        ac += acts.count
                        allActions.append(contentsOf: acts)
                        for a in acts { actionMeeting[a.id] = (s.title ?? "", s.startTime) }
                    }
                    d.meetings.append(ThemeMeetingEntry(id: s.id, title: s.title ?? "", startTime: s.startTime, decisionsCount: dc, actionsCount: ac))
                    d.totalDecisions += dc
                }
                let tracked = CrossMeetingActionTracker.group(allActions)
                d.trackedActions = tracked.map { g in
                    let rep = g.representative
                    let src = actionMeeting[rep.id] ?? ("", rep.timestamp)
                    return TrackedActionDisplay(dbId: rep.id, task: rep.task, owner: rep.assignedTo,
                                                deadline: rep.deadline, priority: rep.priority,
                                                status: rep.status, isOverdue: rep.isOverdue,
                                                mentionCount: g.mentionCount,
                                                sourceMeetingTitle: src.title, sourceMeetingDate: src.date)
                }
                return d
            }.value
            guard selectedThemeId == id else { return }
            themeDetail = detail
            isLoadingThemeDetail = false
        }
    }

    public func cycleActionStatus(dbId: Int64, current: ActionItemStatus) {
        let next: ActionItemStatus
        switch current {
        case .notStarted: next = .inProgress
        case .inProgress: next = .complete
        case .complete: next = .notStarted
        }
        DataStore.shared.updateActionItemStatus(id: dbId, status: next)
        if let id = selectedThemeId { selectTheme(id) }
        if let sid = selectedSession?.sessionId { loadedIds.remove(sid); loadDetail(sid) }
    }

    public func renameTheme(_ id: Int64, to name: String) {
        guard let theme = DataStore.shared.fetchTheme(id: id), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        theme.name = name.trimmingCharacters(in: .whitespaces)
        DataStore.shared.update(theme)
        loadThemes()
    }

    public func setThemeArchived(_ id: Int64, archived: Bool) {
        guard let theme = DataStore.shared.fetchTheme(id: id) else { return }
        theme.archived = archived
        DataStore.shared.update(theme)
        if archived, selectedThemeId == id { selectTheme(nil) }
        loadThemes()
    }

    public func mergeTheme(sourceId: Int64, into targetId: Int64) {
        guard sourceId != targetId else { return }
        DataStore.shared.mergeThemes(from: sourceId, into: targetId)
        selectTheme(selectedThemeId == sourceId ? targetId : selectedThemeId)
        loadThemes()
        refresh()
    }

    public func assignSessionToTheme(sessionId: Int64, themeId: Int64?) {
        DataStore.shared.assignSessionTheme(sessionId: sessionId, themeId: themeId)
        if let item = allSessions.first(where: { $0.sessionId == sessionId }) {
            item.themeId = themeId
            item.themeName = themeId.flatMap { DataStore.shared.fetchTheme(id: $0)?.name }
        }
        loadThemes()
    }

    // MARK: - Minutes regeneration

    public private(set) var isRegenerating = false

    public func regenerateMinutes(templateId: String) {
        guard let selected = selectedSession else { return }
        isRegenerating = true
        statusText = tr("正在按新模板重新生成纪要...", "Regenerating minutes with new template...")
        let llm = AppServices.shared.llm
        Task {
            await Task.detached(priority: .userInitiated) { () -> Void in
                let store = DataStore.shared
                guard let session = store.fetchDetail(sessionId: selected.sessionId) else { return }
                let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
                let screenshots = session.screenshots
                    .filter { $0.analysisStatus == "ready" }
                    .sorted { $0.timestamp < $1.timestamp }
                let features = MeetingFeatureExtractor.extract(session: session)
                let template = MinutesTemplateLibrary.byId(templateId)
                session.templateId = template.id
                session.meetingType = features.predictedType
                let hhmm = DateFormatter(); hhmm.dateFormat = "HH:mm"
                let hhmmss = DateFormatter(); hhmmss.dateFormat = "HH:mm:ss"
                let prompt = MinutesPromptBuilder.build(template: template, features: features,
                                                        session: session, topics: topics,
                                                        screenshots: screenshots,
                                                        hhmm: hhmm, hhmmss: hhmmss)
                if let response = try? await llm.analyze(prompt) {
                    let minutes = StructuredMinutes.parseLlmResponse(response)
                    if !minutes.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        session.summary = minutes.summary
                    }
                    session.minutesJson = minutes.encoded()
                    let quality = MinutesQualityAssessor.assess(minutes: minutes, topics: topics, template: template)
                    session.qualityScore = quality.score
                    session.qualityIssues = quality.issues.isEmpty ? nil : quality.issues.joined(separator: "\n")
                }
                store.update(session)
            }.value
            let sid = selected.sessionId
            loadedIds.remove(sid)
            if let snap = await Self.fetchDetail(id: sid) {
                applyDetail(snap, to: sid)
            }
            if let fresh = await Self.fetchSessionList().first(where: { $0.id == sid }) {
                selected.templateId = fresh.templateId
                selected.meetingType = fresh.meetingType
                selected.qualityScore = fresh.qualityScore
            }
            isRegenerating = false
            statusText = tr("已重新生成", "Regenerated")
        }
    }

    public func exportMinutesMarkdown() {
        guard let selected = selectedSession else { return }
        Task { await exportDoc(selected, kind: .minutes, format: "md") }
    }

    public func exportMinutesHtml() {
        guard let selected = selectedSession else { return }
        Task { await exportDoc(selected, kind: .minutes, format: "html") }
    }

    public func exportRecordMarkdown() {
        guard let selected = selectedSession else { return }
        Task { await exportDoc(selected, kind: .record, format: "md") }
    }

    public func exportRecordHtml() {
        guard let selected = selectedSession else { return }
        Task { await exportDoc(selected, kind: .record, format: "html") }
    }

    public func exportText() {
        guard let selected = selectedSession else { return }
        Task { await exportTextAsync(selected) }
    }

    private func exportDoc(_ session: SessionItem, kind: MinutesRenderer.DocKind, format: String) async {
        await ensureDetailLoaded(session)
        guard let detail = await Task.detached(priority: .userInitiated) { () -> MeetingSession? in
            DataStore.shared.fetchDetail(sessionId: session.sessionId)
        }.value else { return }

        let isMinutes = kind == .minutes
        let prefix = isMinutes ? "MeetingMinutes" : "MeetingRecord"
        let defaultName = "\(prefix)_\(HistoryFormatters.fileStamp.string(from: session.startTime)).\(format)"
        guard let url = askSavePath(defaultName: defaultName, ext: format) else { return }
        do {
            let content: String
            if format == "md" {
                let exportDir = url.deletingLastPathComponent().path
                let mdFileName = url.deletingPathExtension().lastPathComponent
                let assetDir = (exportDir as NSString).appendingPathComponent("\(mdFileName)_files")
                let copiedMap = await Self.copyScreenshotsForExport(session, assetDir: assetDir)
                content = isMinutes
                    ? MinutesRenderer.renderMinutesMarkdown(session: detail,
                                                            template: MinutesTemplateLibrary.byId(detail.templateId),
                                                            screenshotMap: copiedMap,
                                                            assetRelDir: "\(mdFileName)_files")
                    : MinutesRenderer.renderRecordMarkdown(session: detail,
                                                           screenshotMap: copiedMap,
                                                           assetRelDir: "\(mdFileName)_files")
            } else {
                content = isMinutes
                    ? MinutesRenderer.renderMinutesHtml(session: detail,
                                                        template: MinutesTemplateLibrary.byId(detail.templateId))
                    : MinutesRenderer.renderRecordHtml(session: detail)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            statusText = tr("已导出：\(url.lastPathComponent)", "Exported: \(url.lastPathComponent)")
        } catch {
            statusText = tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
        }
    }

    private func exportTextAsync(_ session: SessionItem) async {
        await ensureDetailLoaded(session)
        let defaultName = "Transcript_\(HistoryFormatters.fileStamp.string(from: session.startTime)).txt"
        guard let url = askSavePath(defaultName: defaultName, ext: "txt") else { return }
        do {
            let text = Self.buildTranscriptText(session)
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusText = tr("已导出转写：\(url.lastPathComponent)", "Transcript exported: \(url.lastPathComponent)")
        } catch {
            statusText = tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
        }
    }

    private func askSavePath(defaultName: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func copyScreenshotsForExport(
        _ s: SessionItem, assetDir: String
    ) async -> [String: String] {
        var map: [String: String] = [:]
        let shots = s.screenshotPaths
        guard !shots.isEmpty else { return map }
        try? FileManager.default.createDirectory(atPath: assetDir, withIntermediateDirectories: true)
        var index = 0
        for si in shots {
            index += 1
            let ext = (si.filePath as NSString).pathExtension
            let relName = "screenshot_\(HistoryFormatters.shotStamp.string(from: si.timestamp))_\(index)\(ext.isEmpty ? "" : ".\(ext)")"
            let destPath = (assetDir as NSString).appendingPathComponent(relName)
            do {
                if FileManager.default.fileExists(atPath: si.filePath) {
                    if FileManager.default.fileExists(atPath: destPath) {
                        try FileManager.default.removeItem(atPath: destPath)
                    }
                    try FileManager.default.copyItem(atPath: si.filePath, toPath: destPath)
                    map[si.filePath] = relName
                }
            } catch {
            }
        }
        return map
    }

    private nonisolated static func encodeScreenshotAsDataUri(_ filePath: String) -> String? {
        MinutesRenderer.encodeScreenshotAsDataUri(filePath)
    }

    private nonisolated static func fetchSessionList() async -> [SessionSnapshot] {
        let store = DataStore.shared
        let sessions = store.fetchSessions()
        let counts = store.fetchTranscriptCounts()
        return sessions.map { s in
            let topics = store.fetchTopics(sessionId: s.id)
            let shots = store.fetchScreenshots(sessionId: s.id)
            let defaultTitle = tr("会议 \(HistoryFormatters.monthDay.string(from: s.startTime))", "Meeting \(HistoryFormatters.monthDay.string(from: s.startTime))")
            return SessionSnapshot(
                id: s.id,
                title: s.title ?? defaultTitle,
                startTime: s.startTime,
                endTime: s.endTime,
                summary: s.summary,
                transcriptCount: counts[s.id] ?? 0,
                screenshotCount: shots.count,
                topicTitles: topics.map(\.title),
                screenshots: shots.map {
                    ShotSnapshot(filePath: $0.filePath, timestamp: $0.timestamp,
                                 aiSummary: $0.aiSummary, analysisStatus: $0.analysisStatus,
                                 activeSpeakerName: $0.activeSpeakerName)
                },
                templateId: s.templateId,
                meetingType: s.meetingType,
                qualityScore: s.qualityScore,
                themeId: s.themeId)
        }
    }

    private nonisolated static func fetchDetail(id: Int64) async -> DetailSnapshot? {
        guard let session = DataStore.shared.fetchDetail(sessionId: id) else {
            return nil
        }
        let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
        let topicSummaries = topics.map { $0.summary ?? "" }
        let transcripts = topics
            .flatMap { $0.transcripts.sorted { $0.timestamp < $1.timestamp } }
            .map { TranscriptItem(timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text) }
        let decisions = topics
            .flatMap { $0.decisions.sorted { $0.timestamp < $1.timestamp } }
            .map { DecisionDisplay(text: $0.decisionText, timestamp: $0.timestamp, sourceSpeaker: $0.sourceSpeaker) }
        let actionItems = topics
            .flatMap { $0.actionItems.sorted { $0.timestamp < $1.timestamp } }
            .map { ActionItemDisplay(dbId: $0.id, assignedTo: $0.assignedTo, task: $0.task,
                                     deadline: $0.deadline, priority: $0.priority,
                                     status: $0.status, sourceSpeaker: $0.sourceSpeaker,
                                     timestamp: $0.timestamp) }
        let screenshots = session.screenshots.sorted { $0.timestamp < $1.timestamp }.map {
            ShotSnapshot(filePath: $0.filePath, timestamp: $0.timestamp,
                         aiSummary: $0.aiSummary, analysisStatus: $0.analysisStatus,
                         activeSpeakerName: $0.activeSpeakerName)
        }
        return DetailSnapshot(topicSummaries: topicSummaries, transcripts: transcripts,
                              decisions: decisions, actionItems: actionItems,
                              screenshots: screenshots, summary: session.summary)
    }

    private static func buildTranscriptText(_ s: SessionItem) -> String {
        var lines: [String] = []
        lines.append(s.title)
        lines.append(String(repeating: "-", count: s.title.count))
        lines.append(tr("日期：\(HistoryFormatters.exportDate.string(from: s.startTime))", "Date: \(HistoryFormatters.exportDate.string(from: s.startTime))"))
        lines.append(tr("时长：\(s.durationLabel)", "Duration: \(s.durationLabel)"))
        lines.append(tr("转录条数：\(s.transcriptCount)", "Transcripts: \(s.transcriptCount)"))
        lines.append("")
        for tr in s.transcripts {
            let speaker = (tr.speaker?.isEmpty ?? true) ? "" : "\(tr.speaker!): "
            let text = tr.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            lines.append("[\(tr.timeLabel)] \(speaker)\(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }




}

extension HistoryFormatters {
    static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()
}
