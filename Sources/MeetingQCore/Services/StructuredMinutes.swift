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

public struct StructuredMinutes: Codable, Sendable {
    public struct DecisionItem: Codable, Sendable {
        public var text: String
        public var rationale: String?
        public var sourceSpeaker: String?
    }

    public struct ActionItemFull: Codable, Sendable {
        public var task: String
        public var owner: String
        public var deadline: String?
        public var priority: String?
        public var sourceSpeaker: String?
    }

    public struct TopicDetail: Codable, Sendable {
        public var title: String
        public var points: [String]
    }

    public var summary: String = ""
    public var decisions: [DecisionItem] = []
    public var actionItems: [ActionItemFull] = []
    public var risks: [String] = []
    public var openQuestions: [String] = []
    public var highlights: [String] = []
    public var nextSteps: [String] = []
    public var topicDetails: [TopicDetail] = []

    public init() {}

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> StructuredMinutes? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StructuredMinutes.self, from: data)
    }

    public static func parseLlmResponse(_ response: String) -> StructuredMinutes {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```\w*\n?|\n?```$"#, with: "", options: .regularExpression)
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), end > start {
            text = String(text[start...end])
        }
        var minutes = StructuredMinutes()
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            minutes.summary = response
            return minutes
        }

        minutes.summary = root["summary"] as? String ?? ""
        minutes.risks = stringArray(root, keys: ["risks", "risk_items"])
        minutes.openQuestions = stringArray(root, keys: ["open_questions", "openQuestions"])
        minutes.highlights = stringArray(root, keys: ["key_highlights", "highlights"])
        minutes.nextSteps = stringArray(root, keys: ["next_steps", "nextSteps"])

        if let raw = root["decisions"] as? [Any] {
            for item in raw {
                if let s = item as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    minutes.decisions.append(DecisionItem(text: s, rationale: nil, sourceSpeaker: nil))
                } else if let obj = item as? [String: Any], let s = obj["text"] as? String {
                    minutes.decisions.append(DecisionItem(
                        text: s,
                        rationale: obj["rationale"] as? String,
                        sourceSpeaker: obj["source_speaker"] as? String ?? obj["speaker"] as? String))
                }
            }
        }
        if let raw = root["action_items"] as? [Any] ?? root["actionItems"] as? [Any] ?? root["actions"] as? [Any] {
            for item in raw {
                guard let obj = item as? [String: Any] else { continue }
                let task = obj["task"] as? String ?? ""
                if task.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                minutes.actionItems.append(ActionItemFull(
                    task: task,
                    owner: obj["owner"] as? String ?? obj["assignedTo"] as? String ?? "",
                    deadline: obj["deadline"] as? String ?? obj["due_date"] as? String,
                    priority: normalizePriority(obj["priority"] as? String),
                    sourceSpeaker: obj["source_speaker"] as? String ?? obj["speaker"] as? String))
            }
        }
        if let raw = root["topic_details"] as? [Any] ?? root["agenda"] as? [Any] {
            for item in raw {
                guard let obj = item as? [String: Any], let title = obj["title"] as? String else { continue }
                let points = (obj["points"] as? [Any])?.compactMap { $0 as? String } ?? []
                minutes.topicDetails.append(TopicDetail(title: title, points: points))
            }
        }
        return minutes
    }

    private static func stringArray(_ root: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let arr = root[key] as? [Any] {
                let out = arr.compactMap { $0 as? String }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !out.isEmpty { return out }
            }
        }
        return []
    }

    public static func normalizePriority(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("高") || lower == "high" || lower == "p0" || lower == "p1" { return "high" }
        if lower.contains("低") || lower == "low" || lower == "p3" { return "low" }
        if lower.contains("中") || lower == "medium" || lower == "mid" || lower == "p2" { return "medium" }
        return nil
    }

    public static func priorityIcon(_ priority: String?) -> String {
        switch priority {
        case "high": return "🔴"
        case "medium": return "🟡"
        case "low": return "🟢"
        default: return "⚪"
        }
    }
}

public enum MinutesPromptBuilder {
    public static func build(template: MinutesTemplate,
                             features: MeetingFeatures,
                             session: MeetingSession,
                             topics: [Topic],
                             screenshots: [Screenshot],
                             hhmm: DateFormatter,
                             hhmmss: DateFormatter) -> String {
        let en = AppLanguage.current.isEnglish
        var sb = ""

        sb += template.role + "\n\n"

        let duration: String
        if let end = session.endTime {
            let seconds = Int(end.timeIntervalSince(session.startTime))
            duration = String(format: "%02d:%02d", seconds / 3600, (seconds / 60) % 60)
        } else {
            duration = en ? "unknown" : "未知"
        }
        let fullFormatter = DateFormatter()
        fullFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        if en {
            sb += "[Meeting Metadata]\n"
            sb += "Title: \(session.title ?? "Untitled")\n"
            sb += "Time: \(fullFormatter.string(from: session.startTime)) to \(session.endTime.map { fullFormatter.string(from: $0) } ?? "in progress")\n"
            sb += "Duration: \(duration)\n"
            sb += "Detected type: \(TemplateRecommender.meetingTypeName(features.predictedType))\n\n"
            sb += "[Topic Overview]\n"
        } else {
            sb += "【会议元数据】\n"
            sb += "标题：\(session.title ?? "未命名")\n"
            sb += "时间：\(fullFormatter.string(from: session.startTime)) 至 \(session.endTime.map { fullFormatter.string(from: $0) } ?? "进行中")\n"
            sb += "时长：\(duration)\n"
            sb += "识别类型：\(TemplateRecommender.meetingTypeName(features.predictedType))\n\n"
            sb += "【议题概览】\n"
        }
        for (i, t) in topics.enumerated() {
            sb += en
                ? "Topic \(i + 1): \(t.title) (\(hhmm.string(from: t.startTime)) - \(t.endTime.map { hhmm.string(from: $0) } ?? "now"))\n"
                : "议题\(i + 1)：\(t.title)（\(hhmm.string(from: t.startTime)) - \(t.endTime.map { hhmm.string(from: $0) } ?? "至今")）\n"
            if let summary = t.summary, !summary.trimmingCharacters(in: .whitespaces).isEmpty {
                sb += (en ? "  Summary: " : "  摘要：") + summary + "\n"
            }
        }
        sb += "\n"

        let allDecisions = topics.flatMap(\.decisions)
        if !allDecisions.isEmpty {
            sb += en ? "[All Decisions]\n" : "【所有决策】\n"
            for d in allDecisions {
                sb += "- [\(hhmmss.string(from: d.timestamp))] \(d.decisionText)"
                    + (d.sourceSpeaker.map { en ? " (by \($0))" : "（\($0)）" } ?? "") + "\n"
            }
            sb += "\n"
        }

        let allActions = topics.flatMap(\.actionItems)
        if !allActions.isEmpty {
            sb += en ? "[All Action Items]\n" : "【所有行动项】\n"
            for a in allActions {
                sb += "- [\(hhmmss.string(from: a.timestamp))] \(a.assignedTo): \(a.task)" + (a.deadline.map { en ? " (due \($0))" : "（截止 \($0)）" } ?? "") + "\n"
            }
            sb += "\n"
        }

        let relevantShots = screenshots.filter { $0.meetingRelevance == "high" || $0.meetingRelevance == "medium" }
        if !relevantShots.isEmpty {
            sb += en
                ? "[Screen Content Analysis] (key screenshots during the meeting)\n"
                : "【屏幕内容分析】（会议期间关键截图）\n"
            var charCount = 0
            for s in relevantShots {
                var line = "[\(hhmmss.string(from: s.timestamp))] "
                    + (en ? "type: " : "类型：") + (s.contentType ?? "unknown")
                    + " | " + (en ? "content: " : "内容：") + (s.aiSummary ?? "")
                if let ocr = s.ocrText, !ocr.trimmingCharacters(in: .whitespaces).isEmpty {
                    line += (en ? " | key text: " : " | 关键文字：") + ocr
                }
                if let numbers = s.keyNumbers, !numbers.isEmpty, numbers != "[]" {
                    line += (en ? " | key numbers: " : " | 关键数据：") + numbers
                }
                if let dates = s.keyDates, !dates.isEmpty, dates != "[]" {
                    line += (en ? " | key dates: " : " | 关键日期：") + dates
                }
                if let dec = s.slideDecisions, !dec.isEmpty, dec != "[]" {
                    line += (en ? " | decisions on slide: " : " | 页面决策：") + dec
                }
                if let acts = s.slideActionItems, !acts.isEmpty, acts != "[]" {
                    line += (en ? " | action items on slide: " : " | 页面行动项：") + acts
                }
                if let insight = s.chartInsight, !insight.isEmpty {
                    line += (en ? " | chart insight: " : " | 图表洞察：") + insight
                }
                if charCount + line.count > 4000 { break }
                sb += line + "\n"
                charCount += line.count + 1
            }
            sb += "\n"
        }

        if !template.extraGuidance.isEmpty {
            sb += (en ? "[Template Guidance]\n" : "【模板要求】\n") + template.extraGuidance + "\n\n"
        }

        sb += outputSchema(template: template, en: en)
        return sb
    }

    private static func outputSchema(template: MinutesTemplate, en: Bool) -> String {
        var fields: [String] = []
        fields.append(en
            ? "\"summary\": \"3-5 sentence executive summary: goals, key discussion, outcomes\""
            : "\"summary\": \"3-5句话的整体概述：会议目标、讨论要点、核心成果\"")

        for section in template.sections {
            switch section {
            case .coreSummary: break
            case .decisions:
                fields.append(en
                    ? "\"decisions\": [{\"text\": \"conclusion statement\", \"rationale\": \"why\", \"source_speaker\": \"who said it or null\"}]"
                    : "\"decisions\": [{\"text\": \"结论性语句\", \"rationale\": \"决策依据\", \"source_speaker\": \"提出人，未知则null\"}]")
            case .actionItems:
                fields.append(en
                    ? "\"action_items\": [{\"task\": \"specific task\", \"owner\": \"owner\", \"deadline\": \"YYYY-MM-DD or null\", \"priority\": \"high/medium/low\", \"source_speaker\": \"who proposed or null\"}]"
                    : "\"action_items\": [{\"task\": \"具体任务\", \"owner\": \"负责人\", \"deadline\": \"YYYY-MM-DD 或 null\", \"priority\": \"high/medium/low\", \"source_speaker\": \"提出人，未知则null\"}]")
            case .risks:
                fields.append(en
                    ? "\"risks\": [\"risk or unconfirmed item with impact\"]"
                    : "\"risks\": [\"风险或待确认事项，含影响描述\"]")
            case .openQuestions:
                fields.append(en
                    ? "\"open_questions\": [\"unresolved question\"]"
                    : "\"open_questions\": [\"未解决的问题\"]")
            case .topicDetails:
                fields.append(en
                    ? "\"topic_details\": [{\"title\": \"topic name\", \"points\": [\"3-5 discussion points\"]}]"
                    : "\"topic_details\": [{\"title\": \"议题名\", \"points\": [\"3-5条讨论要点\"]}]")
            case .highlights:
                fields.append(en
                    ? "\"key_highlights\": [\"highlight 1\", \"highlight 2\"]"
                    : "\"key_highlights\": [\"要点1\", \"要点2\"]")
            case .nextSteps:
                fields.append(en
                    ? "\"next_steps\": [\"suggested follow-up\"]"
                    : "\"next_steps\": [\"后续行动建议\"]")
            }
        }

        var sb = en
            ? "[Output Requirements]\nReturn JSON only (no Markdown fences). Cross-check decisions/action items with both the transcript-derived lists and the screen content above; merge duplicates and prefer the most precise wording. Use empty arrays when a section has no content.\n{\n  "
            : "【输出要求】\n只返回JSON（不要Markdown代码块）。决策与行动项需与上方转写提取结果和屏幕内容交叉核对，合并重复项，采用最准确的表述。无内容的章节返回空数组。\n{\n  "
        sb += fields.joined(separator: ",\n  ")
        sb += "\n}\n"
        return sb
    }
}
