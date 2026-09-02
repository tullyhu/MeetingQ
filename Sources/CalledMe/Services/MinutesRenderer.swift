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

public enum MinutesRenderer {
    public enum DocKind { case minutes, record }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    public static func statusIcon(_ item: ActionItem) -> String {
        if item.isOverdue { return "🔴" }
        switch item.status {
        case .complete: return "✅"
        case .inProgress: return "⏳"
        case .notStarted: return "⏳"
        }
    }

    public static func statusLabel(_ item: ActionItem) -> String {
        if item.isOverdue { return tr("已逾期", "Overdue") }
        switch item.status {
        case .complete: return tr("已完成", "Done")
        case .inProgress: return tr("进行中", "In progress")
        case .notStarted: return tr("待开始", "Not started")
        }
    }

    private static func topicTitle(for topicId: Int64, in topics: [Topic]) -> String {
        topics.first(where: { $0.id == topicId })?.title ?? ""
    }

    // MARK: - Minutes (会议纪要)

    public static func renderMinutesMarkdown(session: MeetingSession,
                                             template: MinutesTemplate,
                                             screenshotMap: [String: String],
                                             assetRelDir: String) -> String {
        let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
        let minutes = StructuredMinutes.decode(session.minutesJson)
        let decisions = collectDecisions(topics: topics, minutes: minutes)
        let actions = collectActions(topics: topics, minutes: minutes)
        let en = AppLanguage.current.isEnglish

        var out: [String] = []
        out.append(tr("# 会议纪要 — \(session.title ?? "未命名会议")", "# Meeting Minutes — \(session.title ?? "Untitled")"))
        out.append("")
        out.append("**\(tr("日期", "Date"))**：\(dayFmt.string(from: session.startTime))  ")
        out.append("**\(tr("时长", "Duration"))**：\(durationLabel(session))  ")
        out.append("**\(tr("会议类型", "Type"))**：\(TemplateRecommender.meetingTypeName(session.meetingType ?? "general_meeting"))  ")
        out.append("**\(tr("纪要模板", "Template"))**：\(template.name)  ")
        if let score = session.qualityScore {
            out.append("**\(tr("质量评分", "Quality"))**：\(score)/100  ")
        }
        out.append("")
        out.append("---")
        out.append("")

        for section in template.sections {
            switch section {
            case .coreSummary:
                out.append("## \(section.title)")
                out.append("")
                let summary = minutes?.summary.isEmpty == false ? minutes!.summary : (session.summary ?? "")
                if !summary.isEmpty { out.append(summary); out.append("") }
                if !decisions.isEmpty {
                    out.append("> ### 🔑 \(tr("关键决策", "Key Decisions"))")
                    for d in decisions.prefix(4) { out.append("> - ✅ **\(md(d.text))**\(d.rationale.map { " — \($0)" } ?? "")") }
                    out.append("")
                }
                if !actions.isEmpty {
                    out.append("> ### ✅ \(tr("核心行动项", "Core Action Items"))")
                    for a in actions.prefix(5) {
                        out.append("> - \(StructuredMinutes.priorityIcon(a.priority)) **\(md(a.task))** — \(tr("负责人", "Owner"))：\(md(a.owner)) | \(tr("截止", "Due"))：\(a.deadline ?? "—")")
                    }
                    out.append("")
                }
                let risks = minutes?.risks ?? []
                if !risks.isEmpty {
                    out.append("> ### ⚠️ \(tr("关键风险/待确认", "Key Risks / Pending"))")
                    for r in risks.prefix(4) { out.append("> - \(md(r))") }
                    out.append("")
                }

            case .topicDetails:
                let details = minutes?.topicDetails ?? []
                if !details.isEmpty {
                    out.append("## \(section.title)")
                    out.append("")
                    for td in details {
                        out.append("### \(md(td.title))")
                        for p in td.points { out.append("- \(md(p))") }
                        out.append("")
                    }
                } else if topics.count > 1 || topics.first?.summary != nil {
                    out.append("## \(section.title)")
                    out.append("")
                    for t in topics {
                        guard let s = t.summary, !s.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        out.append("### \(md(t.title))")
                        out.append(s)
                        out.append("")
                    }
                }

            case .highlights:
                let highlights = minutes?.highlights ?? []
                if !highlights.isEmpty {
                    out.append("## \(section.title)")
                    out.append("")
                    for h in highlights { out.append("- \(md(h))") }
                    out.append("")
                }

            case .decisions:
                if !decisions.isEmpty {
                    out.append("## \(section.title)")
                    out.append("")
                    for (i, d) in decisions.enumerated() {
                        var line = "\(i + 1). **\(md(d.text))**"
                        if let r = d.rationale, !r.isEmpty { line += "  \n   \(tr("依据", "Rationale"))：\(md(r))" }
                        if let ts = d.timestamp {
                            line += "  \n   *\(tr("来源", "Source"))：[\(timeFmt.string(from: ts))]\(d.speaker.map { " \($0)" } ?? "")*"
                        }
                        out.append(line)
                    }
                    out.append("")
                }

            case .risks:
                let risks = minutes?.risks ?? []
                if !risks.isEmpty {
                    out.append("## \(section.title)")
                    out.append("")
                    for r in risks { out.append("- ⚠️ \(md(r))") }
                    out.append("")
                }

            case .openQuestions:
                let questions = minutes?.openQuestions ?? []
                if !questions.isEmpty {
                    out.append("## \(section.title)")
                    out.append("")
                    for q in questions { out.append("- ❓ \(md(q))") }
                    out.append("")
                }

            case .actionItems:
                if !actions.isEmpty {
                    out.append("## \(tr("待办事项总表", "Action Item Summary"))")
                    out.append("")
                    if en {
                        out.append("| # | Task | Owner | Due | Priority | Status | Topic |")
                        out.append("|---|------|-------|-----|----------|--------|-------|")
                    } else {
                        out.append("| # | 任务 | 负责人 | 截止日 | 优先级 | 状态 | 来源议题 |")
                        out.append("|---|------|--------|--------|--------|------|----------|")
                    }
                    for (i, a) in actions.enumerated() {
                        out.append("| \(i + 1) | \(md(a.task)) | \(md(a.owner)) | \(a.deadline ?? "—") | \(StructuredMinutes.priorityIcon(a.priority)) | \(a.statusLabel) | \(md(a.topic)) |")
                    }
                    out.append("")
                }

            case .nextSteps:
                let steps = minutes?.nextSteps ?? []
                if !steps.isEmpty {
                    out.append("## \(section.title)")
                    out.append("")
                    for s in steps { out.append("- \(md(s))") }
                    out.append("")
                }
            }
        }

        let relShots = session.screenshots.filter { screenshotMap[$0.filePath] != nil }
        if !relShots.isEmpty {
            out.append("## \(tr("会议截图", "Screenshots"))")
            out.append("")
            for s in relShots {
                guard let rel = screenshotMap[s.filePath] else { continue }
                out.append("![\(timeFmt.string(from: s.timestamp))](\(assetRelDir)/\(rel))  ")
                if let ai = s.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append("> \(md(ai))  ")
                }
                out.append("")
            }
        }

        out.append("---")
        out.append("*\(tr("由 CalledMe 生成", "Generated by CalledMe")) — \(dayFmt.string(from: Date()))*")
        return out.joined(separator: "\n") + "\n"
    }

    public static func renderMinutesHtml(session: MeetingSession, template: MinutesTemplate) -> String {
        let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
        let minutes = StructuredMinutes.decode(session.minutesJson)
        let decisions = collectDecisions(topics: topics, minutes: minutes)
        let actions = collectActions(topics: topics, minutes: minutes)

        var h: [String] = []
        h.append(htmlHead(title: tr("会议纪要 — ", "Meeting Minutes — ") + (session.title ?? ""), kind: .minutes))
        h.append("<body><div class=\"page\">")

        h.append("<div class=\"header-band\">")
        h.append("<span class=\"doc-kind\">\(tr("会议纪要", "MEETING MINUTES"))</span>")
        h.append("<span class=\"confidential\">\(tr("内部", "INTERNAL"))</span>")
        h.append("</div>")
        h.append("<h1>\(eh(session.title ?? tr("未命名会议", "Untitled")))</h1>")
        h.append("<p class=\"meta\">")
        h.append("<span>\(tr("日期：", "Date: "))\(dayFmt.string(from: session.startTime))</span>")
        h.append("<span>\(tr("时长：", "Duration: "))\(durationLabel(session))</span>")
        h.append("<span class=\"badge badge-type\">\(TemplateRecommender.meetingTypeName(session.meetingType ?? "general_meeting"))</span>")
        h.append("<span class=\"badge\">\(template.name)</span>")
        if let score = session.qualityScore {
            let cls = score >= 90 ? "badge-good" : (score >= 70 ? "badge-warn" : "badge-bad")
            h.append("<span class=\"badge \(cls)\">\(tr("质量 ", "Quality "))\(score)</span>")
        }
        h.append("</p>")

        for section in template.sections {
            switch section {
            case .coreSummary:
                let summary = minutes?.summary.isEmpty == false ? minutes!.summary : (session.summary ?? "")
                h.append("<div class=\"callout callout-summary\">")
                h.append("<h2>\(section.title)</h2>")
                if !summary.isEmpty { h.append("<p>\(eh(summary))</p>") }
                if !decisions.isEmpty {
                    h.append("<div class=\"mini-block decision-block\"><h4>🔑 \(tr("关键决策", "Key Decisions"))</h4><ul>")
                    for d in decisions.prefix(4) { h.append("<li><strong>\(eh(d.text))</strong></li>") }
                    h.append("</ul></div>")
                }
                if !actions.isEmpty {
                    h.append("<div class=\"mini-block action-block\"><h4>✅ \(tr("核心行动项", "Core Action Items"))</h4><ul>")
                    for a in actions.prefix(5) {
                        h.append("<li>\(StructuredMinutes.priorityIcon(a.priority)) <strong>\(eh(a.task))</strong> — \(eh(a.owner)) | \(a.deadline ?? "—")</li>")
                    }
                    h.append("</ul></div>")
                }
                let risks = minutes?.risks ?? []
                if !risks.isEmpty {
                    h.append("<div class=\"mini-block risk-block\"><h4>⚠️ \(tr("关键风险/待确认", "Key Risks / Pending"))</h4><ul>")
                    for r in risks.prefix(4) { h.append("<li>\(eh(r))</li>") }
                    h.append("</ul></div>")
                }
                h.append("</div>")

            case .topicDetails:
                let details = minutes?.topicDetails ?? []
                if !details.isEmpty {
                    h.append("<h2>\(section.title)</h2>")
                    for td in details {
                        h.append("<h3>\(eh(td.title))</h3><ul>")
                        for p in td.points { h.append("<li>\(eh(p))</li>") }
                        h.append("</ul>")
                    }
                } else {
                    let withSummary = topics.filter { !($0.summary?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
                    if !withSummary.isEmpty {
                        h.append("<h2>\(section.title)</h2>")
                        for t in withSummary {
                            h.append("<h3>\(eh(t.title))</h3><p>\(eh(t.summary ?? ""))</p>")
                        }
                    }
                }

            case .highlights:
                let highlights = minutes?.highlights ?? []
                if !highlights.isEmpty {
                    h.append("<h2>\(section.title)</h2><ul>")
                    for hl in highlights { h.append("<li>\(eh(hl))</li>") }
                    h.append("</ul>")
                }

            case .decisions:
                if !decisions.isEmpty {
                    h.append("<h2>\(section.title)</h2>")
                    for (i, d) in decisions.enumerated() {
                        h.append("<div class=\"callout callout-decision\">")
                        h.append("<strong>D-\(String(format: "%03d", i + 1))</strong> \(eh(d.text))")
                        if let r = d.rationale, !r.isEmpty {
                            h.append("<div class=\"sub\">\(tr("依据：", "Rationale: "))\(eh(r))</div>")
                        }
                        if let ts = d.timestamp {
                            h.append("<div class=\"src\">\(tr("来源", "Source")): [\(timeFmt.string(from: ts))]\(d.speaker.map { " \(eh($0))" } ?? "")</div>")
                        }
                        h.append("</div>")
                    }
                }

            case .risks:
                let risks = minutes?.risks ?? []
                if !risks.isEmpty {
                    h.append("<h2>\(section.title)</h2>")
                    for r in risks { h.append("<div class=\"callout callout-risk\">⚠️ \(eh(r))</div>") }
                }

            case .openQuestions:
                let questions = minutes?.openQuestions ?? []
                if !questions.isEmpty {
                    h.append("<h2>\(section.title)</h2><ul>")
                    for q in questions { h.append("<li>❓ \(eh(q))</li>") }
                    h.append("</ul>")
                }

            case .actionItems:
                if !actions.isEmpty {
                    h.append("<h2>\(tr("待办事项总表", "Action Item Summary"))</h2>")
                    h.append("<table><thead><tr><th>#</th><th>\(tr("任务", "Task"))</th><th>\(tr("负责人", "Owner"))</th><th>\(tr("截止日", "Due"))</th><th>\(tr("优先级", "Priority"))</th><th>\(tr("状态", "Status"))</th><th>\(tr("来源议题", "Topic"))</th></tr></thead><tbody>")
                    for (i, a) in actions.enumerated() {
                        let stCls = a.isOverdue ? "status-overdue" : (a.status == .complete ? "status-done" : "status-open")
                        h.append("<tr><td>\(i + 1)</td><td>\(eh(a.task))</td><td>\(eh(a.owner))</td><td>\(a.deadline ?? "—")</td><td>\(StructuredMinutes.priorityIcon(a.priority))</td><td class=\"\(stCls)\">\(a.statusLabel)</td><td>\(eh(a.topic))</td></tr>")
                    }
                    h.append("</tbody></table>")
                }

            case .nextSteps:
                let steps = minutes?.nextSteps ?? []
                if !steps.isEmpty {
                    h.append("<h2>\(section.title)</h2><ul>")
                    for s in steps { h.append("<li>\(eh(s))</li>") }
                    h.append("</ul>")
                }
            }
        }

        let shots = session.screenshots.filter { $0.analysisStatus == "ready" }
        if !shots.isEmpty {
            h.append("<h2>\(tr("会议截图", "Screenshots"))</h2>")
            for s in shots {
                if let uri = encodeScreenshotAsDataUri(s.filePath) {
                    h.append("<div class=\"screenshot-block\"><img src=\"\(uri)\" loading=\"lazy\">")
                    h.append("<div class=\"screenshot-label\">\(timeFmt.string(from: s.timestamp))</div>")
                    if let ai = s.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        h.append("<p class=\"shot-summary\">\(eh(ai))</p>")
                    }
                    h.append("</div>")
                }
            }
        }

        h.append("<footer>\(tr("由 CalledMe 生成", "Generated by CalledMe")) — \(dayFmt.string(from: Date()))</footer>")
        h.append("</div></body></html>")
        return h.joined(separator: "\n")
    }

    // MARK: - Record (会议记录)

    public static func renderRecordMarkdown(session: MeetingSession,
                                            screenshotMap: [String: String],
                                            assetRelDir: String) -> String {
        let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
        var out: [String] = []
        out.append(tr("# 会议记录 — \(session.title ?? "未命名会议")", "# Meeting Record — \(session.title ?? "Untitled")"))
        out.append("")
        out.append("**\(tr("日期", "Date"))**：\(dayFmt.string(from: session.startTime))  ")
        out.append("**\(tr("时长", "Duration"))**：\(durationLabel(session))  ")
        out.append("**\(tr("转写方式", "Transcription"))**：\(tr("设备端实时转写", "On-device live transcription"))  ")
        out.append("")

        out.append("## \(tr("议程时间线", "Agenda Timeline"))")
        out.append("")
        for t in topics {
            let end = t.endTime.map { timeFmt.string(from: $0) } ?? "—"
            out.append("- \(timeFmt.string(from: t.startTime)) - \(end)  \(md(t.title))")
        }
        out.append("")
        out.append("---")
        out.append("")

        out.append("## \(tr("会议记录正文", "Transcript"))")
        out.append("")
        for t in topics {
            let end = t.endTime.map { timeFmt.string(from: $0) } ?? tr("至今", "now")
            out.append("### \(timeFmt.string(from: t.startTime)) - \(end)  \(md(t.title))")
            out.append("")
            let transcripts = t.transcripts.sorted { $0.timestamp < $1.timestamp }
            let decisions = t.decisions.sorted { $0.timestamp < $1.timestamp }
            let actions = t.actionItems.sorted { $0.timestamp < $1.timestamp }
            out.append(contentsOf: renderRecordBodyMarkdown(transcripts: transcripts,
                                                            decisions: decisions,
                                                            actions: actions,
                                                            screenshots: session.screenshots,
                                                            topicStart: t.startTime,
                                                            topicEnd: t.endTime,
                                                            screenshotMap: screenshotMap,
                                                            assetRelDir: assetRelDir))
            out.append("")
        }

        appendMomentIndexMarkdown(&out, topics: topics)
        out.append("---")
        out.append("*\(tr("由 CalledMe 生成", "Generated by CalledMe")) — \(dayFmt.string(from: Date()))*")
        return out.joined(separator: "\n") + "\n"
    }

    private static func renderRecordBodyMarkdown(transcripts: [Transcript],
                                                 decisions: [Decision],
                                                 actions: [ActionItem],
                                                 screenshots: [Screenshot],
                                                 topicStart: Date,
                                                 topicEnd: Date?,
                                                 screenshotMap: [String: String],
                                                 assetRelDir: String) -> [String] {
        struct Marker {
            let ts: Date
            let lines: [String]
        }
        var markers: [Marker] = []
        for d in decisions {
            markers.append(Marker(ts: d.timestamp, lines: [
                "> 🔑 **\(tr("决策点", "Decision"))**",
                "> \(md(d.decisionText))",
                "> *\(tr("来源", "Source"))：[\(timeFmt.string(from: d.timestamp))]\(d.sourceSpeaker.map { " \(md($0))" } ?? "")*",
                ""
            ]))
        }
        for a in actions {
            markers.append(Marker(ts: a.timestamp, lines: [
                "> ✅ **\(tr("行动项", "Action Item"))**",
                "> \(md(a.task)) — \(tr("负责人", "Owner"))：\(md(a.assignedTo))\(a.deadline.map { " | \(tr("截止", "Due"))：\($0)" } ?? "")",
                "> *\(tr("来源", "Source"))：[\(timeFmt.string(from: a.timestamp))]\(a.sourceSpeaker.map { " \(md($0))" } ?? "")*",
                ""
            ]))
        }
        let shots = screenshots
            .filter { $0.timestamp >= topicStart && (topicEnd == nil || $0.timestamp <= topicEnd!) }
            .sorted { $0.timestamp < $1.timestamp }

        var out: [String] = []
        var mi = 0
        var si = 0
        for t in transcripts {
            while si < shots.count && shots[si].timestamp <= t.timestamp {
                out.append(contentsOf: shotMarkdown(shots[si], screenshotMap: screenshotMap, assetRelDir: assetRelDir))
                si += 1
            }
            let speaker = (t.speaker?.isEmpty ?? true) ? "" : "**\(md(t.speaker!))**："
            let text = t.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            out.append("[\(timeFmt.string(from: t.timestamp))] \(speaker)\(text)  ")
            out.append("")
            while mi < markers.count && markers[mi].ts <= t.timestamp {
                out.append(contentsOf: markers[mi].lines)
                mi += 1
            }
        }
        while si < shots.count {
            out.append(contentsOf: shotMarkdown(shots[si], screenshotMap: screenshotMap, assetRelDir: assetRelDir))
            si += 1
        }
        while mi < markers.count {
            out.append(contentsOf: markers[mi].lines)
            mi += 1
        }
        return out
    }

    private static func shotMarkdown(_ s: Screenshot, screenshotMap: [String: String], assetRelDir: String) -> [String] {
        var out: [String] = []
        let label = "\(timeFmt.string(from: s.timestamp)) \(tr("截图", "Screenshot"))"
        if let rel = screenshotMap[s.filePath] {
            out.append("![\(label)](\(assetRelDir)/\(rel))  ")
            out.append("*\(label)*  ")
        } else {
            out.append("> 📷 *\(label)*  ")
        }
        if let ai = s.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("> \(md(ai))  ")
        }
        out.append("")
        return out
    }

    private static func appendMomentIndexMarkdown(_ out: inout [String], topics: [Topic]) {
        let decisions = topics.flatMap(\.decisions).sorted { $0.timestamp < $1.timestamp }
        let actions = topics.flatMap(\.actionItems).sorted { $0.timestamp < $1.timestamp }
        guard !decisions.isEmpty || !actions.isEmpty else { return }
        out.append("## \(tr("关键片段索引", "Key Moments Index"))")
        out.append("")
        if !decisions.isEmpty {
            out.append("### 🔑 \(tr("决策点", "Decisions"))（\(decisions.count)）")
            for (i, d) in decisions.enumerated() {
                out.append("\(i + 1). [\(timeFmt.string(from: d.timestamp))] \(md(d.decisionText))\(d.sourceSpeaker.map { " — \(md($0))" } ?? "")")
            }
            out.append("")
        }
        if !actions.isEmpty {
            out.append("### ✅ \(tr("行动项", "Action Items"))（\(actions.count)）")
            for (i, a) in actions.enumerated() {
                out.append("\(i + 1). [\(timeFmt.string(from: a.timestamp))] \(md(a.task)) — \(tr("负责人", "Owner"))：\(md(a.assignedTo))\(a.deadline.map { " | \(tr("截止", "Due"))：\($0)" } ?? "")")
            }
            out.append("")
        }
    }

    public static func renderRecordHtml(session: MeetingSession) -> String {
        let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
        var h: [String] = []
        h.append(htmlHead(title: tr("会议记录 — ", "Meeting Record — ") + (session.title ?? ""), kind: .record))
        h.append("<body><div class=\"page\">")
        h.append("<div class=\"header-band\"><span class=\"doc-kind\">\(tr("会议记录", "MEETING RECORD"))</span></div>")
        h.append("<h1>\(eh(session.title ?? tr("未命名会议", "Untitled")))</h1>")
        h.append("<p class=\"meta\">")
        h.append("<span>\(tr("日期：", "Date: "))\(dayFmt.string(from: session.startTime))</span>")
        h.append("<span>\(tr("时长：", "Duration: "))\(durationLabel(session))</span>")
        h.append("</p>")

        h.append("<h2>\(tr("议程时间线", "Agenda Timeline"))</h2><ul class=\"agenda\">")
        for t in topics {
            let end = t.endTime.map { timeFmt.string(from: $0) } ?? "—"
            h.append("<li><span class=\"ts\">\(timeFmt.string(from: t.startTime)) - \(end)</span> \(eh(t.title))</li>")
        }
        h.append("</ul>")

        h.append("<h2>\(tr("会议记录正文", "Transcript"))</h2>")
        for t in topics {
            let end = t.endTime.map { timeFmt.string(from: $0) } ?? tr("至今", "now")
            h.append("<h3>\(timeFmt.string(from: t.startTime)) - \(end)  \(eh(t.title))</h3>")
            h.append(contentsOf: renderRecordBodyHtml(transcripts: t.transcripts.sorted { $0.timestamp < $1.timestamp },
                                                      decisions: t.decisions.sorted { $0.timestamp < $1.timestamp },
                                                      actions: t.actionItems.sorted { $0.timestamp < $1.timestamp },
                                                      screenshots: session.screenshots,
                                                      topicStart: t.startTime,
                                                      topicEnd: t.endTime))
        }

        let decisions = topics.flatMap(\.decisions).sorted { $0.timestamp < $1.timestamp }
        let actions = topics.flatMap(\.actionItems).sorted { $0.timestamp < $1.timestamp }
        if !decisions.isEmpty || !actions.isEmpty {
            h.append("<h2>\(tr("关键片段索引", "Key Moments Index"))</h2>")
            if !decisions.isEmpty {
                h.append("<h4>🔑 \(tr("决策点", "Decisions"))（\(decisions.count)）</h4><ol>")
                for d in decisions {
                    h.append("<li><span class=\"ts\">[\(timeFmt.string(from: d.timestamp))]</span> \(eh(d.decisionText))\(d.sourceSpeaker.map { " — \(eh($0))" } ?? "")</li>")
                }
                h.append("</ol>")
            }
            if !actions.isEmpty {
                h.append("<h4>✅ \(tr("行动项", "Action Items"))（\(actions.count)）</h4><ol>")
                for a in actions {
                    h.append("<li><span class=\"ts\">[\(timeFmt.string(from: a.timestamp))]</span> \(eh(a.task)) — \(eh(a.assignedTo))\(a.deadline.map { " | \(eh($0))" } ?? "")</li>")
                }
                h.append("</ol>")
            }
        }

        h.append("<footer>\(tr("由 CalledMe 生成", "Generated by CalledMe")) — \(dayFmt.string(from: Date()))</footer>")
        h.append("</div></body></html>")
        return h.joined(separator: "\n")
    }

    private static func renderRecordBodyHtml(transcripts: [Transcript],
                                             decisions: [Decision],
                                             actions: [ActionItem],
                                             screenshots: [Screenshot],
                                             topicStart: Date,
                                             topicEnd: Date?) -> [String] {
        struct Marker {
            let ts: Date
            let html: String
        }
        var markers: [Marker] = []
        for d in decisions {
            markers.append(Marker(ts: d.timestamp, html:
                "<div class=\"callout callout-decision\"><strong>🔑 \(tr("决策点", "Decision"))</strong><br>\(eh(d.decisionText))<div class=\"src\">\(tr("来源", "Source")): [\(timeFmt.string(from: d.timestamp))]\(d.sourceSpeaker.map { " \(eh($0))" } ?? "")</div></div>"))
        }
        for a in actions {
            markers.append(Marker(ts: a.timestamp, html:
                "<div class=\"callout callout-action\"><strong>✅ \(tr("行动项", "Action Item"))</strong><br>\(eh(a.task)) — \(eh(a.assignedTo))\(a.deadline.map { " | \(eh($0))" } ?? "")<div class=\"src\">\(tr("来源", "Source")): [\(timeFmt.string(from: a.timestamp))]\(a.sourceSpeaker.map { " \(eh($0))" } ?? "")</div></div>"))
        }
        markers.sort { $0.ts < $1.ts }
        let shots = screenshots
            .filter { $0.timestamp >= topicStart && (topicEnd == nil || $0.timestamp <= topicEnd!) }
            .sorted { $0.timestamp < $1.timestamp }

        var out: [String] = []
        var mi = 0
        var si = 0
        var row = 0
        for t in transcripts {
            while si < shots.count && shots[si].timestamp <= t.timestamp {
                out.append(shotHtml(shots[si]))
                si += 1
            }
            let speaker = (t.speaker?.isEmpty ?? true) ? "" : "<span class=\"speaker\">\(eh(t.speaker!))</span>"
            out.append("<div class=\"turn \(row % 2 == 0 ? "alt" : "")\"><span class=\"ts\">[\(timeFmt.string(from: t.timestamp))]</span> \(speaker)\(eh(t.text))</div>")
            row += 1
            while mi < markers.count && markers[mi].ts <= t.timestamp {
                out.append(markers[mi].html)
                mi += 1
            }
        }
        while si < shots.count {
            out.append(shotHtml(shots[si]))
            si += 1
        }
        while mi < markers.count {
            out.append(markers[mi].html)
            mi += 1
        }
        return out
    }

    private static func shotHtml(_ s: Screenshot) -> String {
        var b = "<div class=\"screenshot-block\">"
        if let uri = encodeScreenshotAsDataUri(s.filePath) {
            b += "<img src=\"\(uri)\" loading=\"lazy\">"
        }
        b += "<div class=\"screenshot-label\">📷 \(timeFmt.string(from: s.timestamp))</div>"
        if let ai = s.aiSummary, !ai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            b += "<p class=\"shot-summary\">\(eh(ai))</p>"
        }
        b += "</div>"
        return b
    }

    // MARK: - Shared helpers

    private struct DecisionRow {
        let text: String
        let rationale: String?
        let timestamp: Date?
        let speaker: String?
    }

    private static func collectDecisions(topics: [Topic], minutes: StructuredMinutes?) -> [DecisionRow] {
        let stored = topics.flatMap(\.decisions).sorted { $0.timestamp < $1.timestamp }
        guard let minutes, !minutes.decisions.isEmpty else {
            return stored.map { DecisionRow(text: $0.decisionText, rationale: nil, timestamp: $0.timestamp, speaker: $0.sourceSpeaker) }
        }
        return minutes.decisions.map { sd in
            let match = stored.first { ThemeClassifier.similarity($0.decisionText, sd.text) > 0.5 }
            return DecisionRow(text: sd.text,
                               rationale: sd.rationale,
                               timestamp: match?.timestamp,
                               speaker: sd.sourceSpeaker ?? match?.sourceSpeaker)
        }
    }

    private struct ActionRow {
        let task: String
        let owner: String
        let deadline: String?
        let priority: String?
        let timestamp: Date?
        let speaker: String?
        let topic: String
        let status: ActionItemStatus
        let isOverdue: Bool
        var statusLabel: String {
            if isOverdue { return tr("已逾期", "Overdue") }
            switch status {
            case .complete: return tr("已完成", "Done")
            case .inProgress: return tr("进行中", "In progress")
            case .notStarted: return tr("待开始", "Not started")
            }
        }
    }

    private static func collectActions(topics: [Topic], minutes: StructuredMinutes?) -> [ActionRow] {
        let stored = topics.flatMap(\.actionItems).sorted { $0.timestamp < $1.timestamp }
        func row(for a: ActionItem) -> ActionRow {
            ActionRow(task: a.task, owner: a.assignedTo, deadline: a.deadline,
                      priority: a.priority, timestamp: a.timestamp, speaker: a.sourceSpeaker,
                      topic: topics.first(where: { $0.id == a.topicId })?.title ?? "",
                      status: a.status, isOverdue: a.isOverdue)
        }
        guard let minutes, !minutes.actionItems.isEmpty else {
            return stored.map(row(for:))
        }
        return minutes.actionItems.map { sa in
            if let match = stored.first(where: { ThemeClassifier.similarity($0.task, sa.task) > 0.5 }) {
                return ActionRow(task: sa.task, owner: sa.owner.isEmpty ? match.assignedTo : sa.owner,
                                 deadline: sa.deadline ?? match.deadline,
                                 priority: sa.priority ?? match.priority,
                                 timestamp: match.timestamp, speaker: sa.sourceSpeaker ?? match.sourceSpeaker,
                                 topic: topics.first(where: { $0.id == match.topicId })?.title ?? "",
                                 status: match.status, isOverdue: match.isOverdue)
            }
            return ActionRow(task: sa.task, owner: sa.owner, deadline: sa.deadline,
                             priority: sa.priority, timestamp: nil, speaker: sa.sourceSpeaker,
                             topic: "", status: .notStarted, isOverdue: false)
        }
    }

    private static func durationLabel(_ session: MeetingSession) -> String {
        guard let end = session.endTime else { return "—" }
        let total = max(0, Int(end.timeIntervalSince(session.startTime)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours >= 1 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func md(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    static func eh(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func encodeScreenshotAsDataUri(_ filePath: String) -> String? {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        let mime: String
        switch (filePath as NSString).pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "bmp": mime = "image/bmp"
        case "gif": mime = "image/gif"
        default: mime = "image/jpeg"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func htmlHead(title: String, kind: DocKind) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(tr("zh-CN", "en"))">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(eh(title))</title>
        <style>
          * { box-sizing: border-box; }
          body { font-family: -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif; background: #F9FAFB; color: #111827; margin: 0; }
          .page { max-width: 900px; margin: 40px auto; background: #fff; padding: 40px 48px; box-shadow: 0 1px 4px rgba(0,0,0,.08); border-radius: 12px; line-height: 1.6; }
          h1 { font-size: 28px; font-weight: 700; letter-spacing: -0.5px; margin: 12px 0 8px; }
          h2 { font-size: 20px; font-weight: 600; color: #1E40AF; margin-top: 40px; border-bottom: 1px solid #E5E7EB; padding-bottom: 8px; }
          h3 { font-size: 16px; font-weight: 500; margin-top: 24px; }
          h4 { margin: 8px 0 4px; font-size: 14px; }
          p, li { font-size: 14px; }
          .meta { color: #6B7280; font-size: 12px; letter-spacing: 0.5px; }
          .meta span { margin-right: 20px; }
          .header-band { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #1E40AF; padding-bottom: 10px; }
          .doc-kind { font-size: 12px; letter-spacing: 2px; color: #1E40AF; font-weight: 600; }
          .confidential { font-size: 11px; color: #DC2626; border: 1px solid #DC2626; border-radius: 4px; padding: 2px 8px; }
          .badge { display: inline-block; background: #EFF6FF; color: #1E40AF; border-radius: 10px; padding: 1px 10px; font-size: 12px; }
          .badge-type { background: #1E40AF; color: #fff; }
          .badge-good { background: #F0FDF4; color: #059669; }
          .badge-warn { background: #FFFBEB; color: #D97706; }
          .badge-bad { background: #FEF2F2; color: #DC2626; }
          .callout { border-radius: 8px; padding: 14px 18px; margin: 12px 0; font-size: 14px; }
          .callout-summary { background: #EFF6FF; border-left: 4px solid #1E40AF; color: #1E3A8A; }
          .callout-summary h2 { margin-top: 0; border: none; color: #1E3A8A; }
          .callout-decision { background: #EFF6FF; border-left: 4px solid #1E40AF; color: #1E3A8A; }
          .callout-action { background: #F0FDF4; border-left: 4px solid #059669; color: #166534; }
          .callout-risk { background: #FEF2F2; border-left: 4px solid #DC2626; color: #991B1B; }
          .mini-block { margin-top: 10px; }
          .mini-block ul { margin: 4px 0; }
          .sub { color: #6B7280; font-size: 12px; margin-top: 4px; }
          .src { color: #6B7280; font-size: 12px; margin-top: 4px; font-style: italic; }
          table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 14px; }
          th, td { border: 1px solid #E5E7EB; padding: 10px 12px; text-align: left; }
          th { background: #F9FAFB; font-weight: 600; }
          .status-done { color: #059669; font-weight: 600; }
          .status-open { color: #D97706; }
          .status-overdue { color: #DC2626; font-weight: 600; }
          .turn { padding: 6px 10px; font-size: 15px; line-height: 1.7; border-radius: 6px; }
          .turn.alt { background: #F9FAFB; }
          .ts { color: #6B7280; font-size: 11px; font-weight: 500; margin-right: 6px; }
          .speaker { color: #2563EB; font-weight: 500; font-size: 13px; margin-right: 8px; }
          .agenda li { margin: 4px 0; }
          .screenshot-block { margin: 16px 0; }
          .screenshot-block img { max-width: 100%; border: 1px solid #E5E7EB; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,.08); }
          .screenshot-label { color: #9CA3AF; font-size: 12px; margin-top: 4px; }
          .shot-summary { color: #6B7280; font-size: 13px; margin-top: 4px; }
          footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid #E5E7EB; color: #9CA3AF; font-size: 12px; }
          ul { padding-left: 20px; }
          li { margin: 4px 0; }
        </style>
        </head>
        """
    }
}
