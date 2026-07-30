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
    public let assignedTo: String
    public let task: String
    public let deadline: String?

    public var label: String {
        guard let deadline, !deadline.isEmpty else { return tr("\(assignedTo)：\(task)", "\(assignedTo): \(task)") }
        return tr("\(assignedTo)：\(task)（\(deadline)）", "\(assignedTo): \(task) (\(deadline))")
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
    public var decisions: [String] = []
    public var actionItems: [ActionItemDisplay] = []

    public var id: Int64 { sessionId }

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
                topicTitles: [String], screenshotPaths: [ScreenshotItem]) {
        self.sessionId = sessionId
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.overallSummary = overallSummary
        self.transcriptCount = transcriptCount
        self.screenshotCount = screenshotCount
        self.topicTitles = topicTitles
        self.screenshotPaths = screenshotPaths
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
}

private struct DetailSnapshot: Sendable {
    let topicSummaries: [String]
    let transcripts: [TranscriptItem]
    let decisions: [String]
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
    public private(set) var statusText = tr("加载历史会议...", "Loading meeting history...")
    public private(set) var isLoading = true
    public private(set) var isLoadingDetail = false
    public private(set) var loadedIds: Set<Int64> = []

    public var hasSelected: Bool { selectedSession != nil }
    public var filteredCount: Int { sessions.count }
    public var totalCount: Int { allSessions.count }

    private var detailTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?

    public init() {}

    public func refresh() {
        selectedSession = nil
        loadList()
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
        allSessions = snaps.map { s in
            SessionItem(
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
                })
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

    public func exportMarkdown() {
        guard let selected = selectedSession else { return }
        Task { await exportMarkdownAsync(selected) }
    }

    public func exportHtml() {
        guard let selected = selectedSession else { return }
        Task { await exportHtmlAsync(selected) }
    }

    public func exportText() {
        guard let selected = selectedSession else { return }
        Task { await exportTextAsync(selected) }
    }

    private func exportMarkdownAsync(_ session: SessionItem) async {
        await ensureDetailLoaded(session)
        let defaultName = "MeetingMinutes_\(HistoryFormatters.fileStamp.string(from: session.startTime)).md"
        guard let url = askSavePath(defaultName: defaultName, ext: "md") else { return }
        do {
            let exportDir = url.deletingLastPathComponent().path
            let mdFileName = url.deletingPathExtension().lastPathComponent
            let assetDir = (exportDir as NSString).appendingPathComponent("\(mdFileName)_files")
            let assetRel = "\(mdFileName)_files"
            let copiedMap = await Self.copyScreenshotsForExport(session, assetDir: assetDir)
            let md = Self.buildMarkdown(session, assetRelDir: assetRel, screenshotMap: copiedMap)
            try md.write(to: url, atomically: true, encoding: .utf8)
            statusText = tr("已导出：\(url.lastPathComponent)", "Exported: \(url.lastPathComponent)")
        } catch {
            statusText = tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
        }
    }

    private func exportHtmlAsync(_ session: SessionItem) async {
        await ensureDetailLoaded(session)
        let defaultName = "MeetingMinutes_\(HistoryFormatters.fileStamp.string(from: session.startTime)).html"
        guard let url = askSavePath(defaultName: defaultName, ext: "html") else { return }
        do {
            let html = Self.buildHtml(session)
            try html.write(to: url, atomically: true, encoding: .utf8)
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
        do {
            guard FileManager.default.fileExists(atPath: filePath) else { return nil }
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let mime: String
            switch (filePath as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "png": mime = "image/png"
            case "bmp": mime = "image/bmp"
            case "gif": mime = "image/gif"
            default: mime = "image/jpeg"
            }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        } catch {
            return nil
        }
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
                })
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
            .map(\.decisionText)
        let actionItems = topics
            .flatMap { $0.actionItems.sorted { $0.timestamp < $1.timestamp } }
            .map { ActionItemDisplay(assignedTo: $0.assignedTo, task: $0.task, deadline: $0.deadline) }
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

    private static func escapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func buildMarkdown(_ s: SessionItem, assetRelDir: String,
                                                  screenshotMap: [String: String]) -> String {
        var lines: [String] = []
        lines.append(tr("# 会议纪要 — \(s.title)", "# Meeting Minutes — \(s.title)"))
        lines.append("")
        lines.append(tr("**日期：** \(HistoryFormatters.exportDate.string(from: s.startTime))  ", "**Date:** \(HistoryFormatters.exportDate.string(from: s.startTime))  "))
        lines.append(tr("**时长：** \(s.durationLabel)  ", "**Duration:** \(s.durationLabel)  "))
        lines.append(tr("**转录条数：** \(s.transcriptCount)  ", "**Transcripts:** \(s.transcriptCount)  "))
        if !s.screenshotPaths.isEmpty {
            lines.append(tr("**截图数：** \(s.screenshotPaths.count)", "**Screenshots:** \(s.screenshotPaths.count)"))
        }
        lines.append("")

        if let summary = s.overallSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(tr("## 会议总结", "## Summary"))
            lines.append("")
            lines.append("\(escapeMarkdown(summary))  ")
            lines.append("")
        }

        let summaryTexts = s.topicSummaries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !summaryTexts.isEmpty {
            lines.append(tr("## 议题摘要", "## Topic Summaries"))
            lines.append("")
            for t in summaryTexts {
                lines.append("\(escapeMarkdown(t))  ")
                lines.append("")
            }
        }

        if !s.topicTitles.isEmpty {
            lines.append(tr("## 议题", "## Topics"))
            for (i, title) in s.topicTitles.enumerated() {
                lines.append("- **\(title)**")
                if i < s.topicSummaries.count,
                   !s.topicSummaries[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("  \(escapeMarkdown(s.topicSummaries[i]))")
                }
            }
            lines.append("")
        }

        if s.hasDecisions {
            lines.append(tr("## 决策", "## Decisions"))
            for d in s.decisions {
                lines.append("- \(escapeMarkdown(d))")
            }
            lines.append("")
        }

        if s.hasActionItems {
            lines.append(tr("## 行动项", "## Action Items"))
            lines.append(tr("| 负责人 | 任务 | 截止时间 |", "| Owner | Task | Deadline |"))
            lines.append("|--------|------|----------|")
            for a in s.actionItems {
                lines.append("| \(escapeMarkdown(a.assignedTo)) | \(escapeMarkdown(a.task)) | \(escapeMarkdown(a.deadline ?? "—")) |")
            }
            lines.append("")
        }

        if s.hasTranscripts || s.hasScreenshots {
            lines.append(tr("## 会议记录", "## Meeting Log"))
            lines.append("")

            var ti = 0
            var si = 0
            while ti < s.transcripts.count || si < s.screenshotPaths.count {
                let haveTranscript = ti < s.transcripts.count
                let haveScreenshot = si < s.screenshotPaths.count

                if !haveScreenshot || (haveTranscript &&
                    s.transcripts[ti].timestamp <= s.screenshotPaths[si].timestamp) {
                    let tr = s.transcripts[ti]
                    ti += 1
                    let speaker = (tr.speaker?.isEmpty ?? true) ? "" : "**\(tr.speaker!)**: "
                    let text = tr.text
                        .replacingOccurrences(of: "\r\n", with: "  \n")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    lines.append("**\(tr.timeLabel)** \(speaker)\(text)  ")
                    lines.append("")
                } else {
                    let shot = s.screenshotPaths[si]
                    si += 1
                    if let relPath = screenshotMap[shot.filePath] {
                        lines.append("![\(tr("\(shot.timeLabel) 截图", "\(shot.timeLabel) Screenshot"))](\(assetRelDir)/\(relPath))  ")
                        let speakerNote = (shot.activeSpeakerName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                            ? "" : tr(" — 发言人：\(shot.activeSpeakerName!)", " — Speaker: \(shot.activeSpeakerName!)")
                        lines.append("*\(tr("\(shot.timeLabel) 截图", "\(shot.timeLabel) Screenshot"))\(speakerNote)*  ")
                        if let ai = shot.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lines.append("> \(escapeMarkdown(ai))  ")
                        }
                    } else {
                        let speakerNote = (shot.activeSpeakerName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                            ? "" : tr(" — 发言人：\(shot.activeSpeakerName!)", " — Speaker: \(shot.activeSpeakerName!)")
                        lines.append("> 📷 *\(tr("\(shot.timeLabel) 截图（文件缺失）", "\(shot.timeLabel) Screenshot (file missing)"))\(speakerNote)*  ")
                        if let ai = shot.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lines.append("> \(escapeMarkdown(ai))  ")
                        }
                    }
                    lines.append("")
                }
            }
        }

        lines.append("---")
        lines.append("*\(tr("由 CalledMe 生成", "Generated by CalledMe")) — \(HistoryFormatters.footer.string(from: Date()))*")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func buildHtml(_ s: SessionItem) -> String {
        var lines: [String] = []
        lines.append("<!DOCTYPE html>")
        lines.append("<html lang=\"\(tr("zh-CN", "en"))\">")
        lines.append("<head>")
        lines.append("<meta charset=\"UTF-8\">")
        lines.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">")
        lines.append("<title>\(tr("会议纪要 — ", "Meeting Minutes — "))\(escapeHtml(s.title))</title>")
        lines.append("<style>")
        lines.append("  body { font-family: -apple-system, 'Microsoft YaHei', sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; color: #1a1a1a; line-height: 1.7; }")
        lines.append("  h1 { border-bottom: 2px solid #2563eb; padding-bottom: 12px; }")
        lines.append("  h2 { color: #2563eb; margin-top: 32px; }")
        lines.append("  .meta { color: #6b7280; font-size: 14px; }")
        lines.append("  .meta span { margin-right: 24px; }")
        lines.append("  .transcript-entry { margin: 8px 0; padding: 6px 0; }")
        lines.append("  .ts { color: #6b7280; font-size: 13px; font-weight: 600; }")
        lines.append("  .speaker { color: #2563eb; font-weight: 600; }")
        lines.append("  .screenshot-block { margin: 16px 0; }")
        lines.append("  .screenshot-block img { max-width: 100%; border: 1px solid #e5e7eb; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,.08); }")
        lines.append("  .screenshot-label { color: #9ca3af; font-size: 12px; margin-top: 4px; }")
        lines.append("  table { border-collapse: collapse; width: 100%; }")
        lines.append("  th, td { border: 1px solid #e5e7eb; padding: 8px 12px; text-align: left; }")
        lines.append("  th { background: #f3f4f6; font-weight: 600; }")
        lines.append("  ul { padding-left: 20px; }")
        lines.append("  li { margin: 4px 0; }")
        lines.append("  footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid #e5e7eb; color: #9ca3af; font-size: 13px; }")
        lines.append("</style>")
        lines.append("</head>")
        lines.append("<body>")

        lines.append("<h1>\(tr("会议纪要 — ", "Meeting Minutes — "))\(escapeHtml(s.title))</h1>")
        lines.append("<p class=\"meta\">")
        lines.append("<span>\(tr("日期：", "Date: "))\(HistoryFormatters.exportDate.string(from: s.startTime))</span>")
        lines.append("<span>\(tr("时长：", "Duration: "))\(s.durationLabel)</span>")
        lines.append("<span>\(tr("转录条数：", "Transcripts: "))\(s.transcriptCount)</span>")
        if !s.screenshotPaths.isEmpty {
            lines.append("<span>\(tr("截图数：", "Screenshots: "))\(s.screenshotPaths.count)</span>")
        }
        lines.append("</p>")

        if let summary = s.overallSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("<h2>\(tr("会议总结", "Summary"))</h2>")
            lines.append("<p>\(escapeHtml(summary))</p>")
        }

        let summaryTexts = s.topicSummaries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !summaryTexts.isEmpty {
            lines.append("<h2>\(tr("议题摘要", "Topic Summaries"))</h2>")
            for t in summaryTexts {
                lines.append("<p>\(escapeHtml(t))</p>")
            }
        }

        if !s.topicTitles.isEmpty {
            lines.append("<h2>\(tr("议题", "Topics"))</h2><ul>")
            for (i, title) in s.topicTitles.enumerated() {
                let summary = (i < s.topicSummaries.count &&
                               !s.topicSummaries[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ? " — \(escapeHtml(s.topicSummaries[i]))" : ""
                lines.append("<li><strong>\(escapeHtml(title))</strong>\(summary)</li>")
            }
            lines.append("</ul>")
        }

        if s.hasDecisions {
            lines.append("<h2>\(tr("决策", "Decisions"))</h2><ul>")
            for d in s.decisions {
                lines.append("<li>\(escapeHtml(d))</li>")
            }
            lines.append("</ul>")
        }

        if s.hasActionItems {
            lines.append("<h2>\(tr("行动项", "Action Items"))</h2>")
            lines.append("<table><thead><tr><th>\(tr("负责人", "Owner"))</th><th>\(tr("任务", "Task"))</th><th>\(tr("截止时间", "Deadline"))</th></tr></thead><tbody>")
            for a in s.actionItems {
                lines.append("<tr><td>\(escapeHtml(a.assignedTo))</td><td>\(escapeHtml(a.task))</td><td>\(escapeHtml(a.deadline ?? "—"))</td></tr>")
            }
            lines.append("</tbody></table>")
        }

        if s.hasTranscripts || s.hasScreenshots {
            lines.append("<h2>\(tr("会议记录", "Meeting Log"))</h2>")

            var ti = 0
            var si = 0
            while ti < s.transcripts.count || si < s.screenshotPaths.count {
                let haveTranscript = ti < s.transcripts.count
                let haveScreenshot = si < s.screenshotPaths.count

                if !haveScreenshot || (haveTranscript &&
                    s.transcripts[ti].timestamp <= s.screenshotPaths[si].timestamp) {
                    let tr = s.transcripts[ti]
                    ti += 1
                    let speaker = (tr.speaker?.isEmpty ?? true)
                        ? "" : "<span class=\"speaker\">\(escapeHtml(tr.speaker!)):</span>"
                    lines.append("<div class=\"transcript-entry\"><span class=\"ts\">\(tr.timeLabel)</span> \(speaker)\(escapeHtml(tr.text))</div>")
                } else {
                    let shot = s.screenshotPaths[si]
                    si += 1
                    if let dataUri = encodeScreenshotAsDataUri(shot.filePath) {
                        lines.append("<div class=\"screenshot-block\">")
                        lines.append("<img src=\"\(dataUri)\" alt=\"\(tr("\(shot.timeLabel) 截图", "\(shot.timeLabel) Screenshot"))\" loading=\"lazy\">")
                        let speakerNote = (shot.activeSpeakerName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                            ? "" : tr(" — 发言人：", " — Speaker: ") + escapeHtml(shot.activeSpeakerName!)
                        lines.append("<div class=\"screenshot-label\">\(tr("\(shot.timeLabel) 截图", "\(shot.timeLabel) Screenshot"))\(speakerNote)</div>")
                        if let ai = shot.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lines.append("<p style=\"color:#6b7280;font-size:13px;margin-top:4px\">\(escapeHtml(ai))</p>")
                        }
                        lines.append("</div>")
                    } else {
                        let speakerNote = (shot.activeSpeakerName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                            ? "" : tr(" — 发言人：", " — Speaker: ") + escapeHtml(shot.activeSpeakerName!)
                        lines.append("<div class=\"screenshot-block\"><p>📷 \(tr("\(shot.timeLabel) 截图（文件缺失）", "\(shot.timeLabel) Screenshot (file missing)"))\(speakerNote)</p>")
                        if let ai = shot.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lines.append("<p style=\"color:#6b7280;font-size:13px\">\(escapeHtml(ai))</p>")
                        }
                        lines.append("</div>")
                    }
                }
            }
        }

        lines.append("<footer>\(tr("由 CalledMe 生成", "Generated by CalledMe")) — \(HistoryFormatters.footer.string(from: Date()))</footer>")
        lines.append("</body></html>")
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func escapeHtml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension HistoryFormatters {
    static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()
}
