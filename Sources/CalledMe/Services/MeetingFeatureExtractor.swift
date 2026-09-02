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

public struct MeetingFeatures: Sendable {
    public enum Level: String, Sendable { case low, medium, high }

    public var predictedType: String = "general_meeting"
    public var typeConfidence: Double = 0.5
    public var typeScores: [String: Double] = [:]
    public var formality: Level = .medium
    public var decisionDensity: Double = 0
    public var actionDensity: Double = 0
    public var technicalDensity: Double = 0
    public var businessDensity: Double = 0
    public var discussionIntensity: Level = .low
    public var durationMinutes: Int = 0
    public var wordCount: Int = 0
    public var slideCount: Int = 0
    public var chartCount: Int = 0
    public var whiteboardDetected: Bool = false
    public var slideDecisionCount: Int = 0
    public var slideActionItemCount: Int = 0
    public var slideKeyDateCount: Int = 0
}

public enum MeetingFeatureExtractor {
    private static let decisionKeywords = ["决定", "确定", "同意", "通过", "批准", "就这么定", "拍板", "decide", "decided", "decision", "agree", "agreed", "approve", "approved", "confirm", "confirmed", "finalize"]
    private static let actionKeywords = ["需要", "负责", "跟进", "完成", "提交", "我来", "你来做", "落实", "安排", "todo", "action item", "follow up", "owner", "deadline", "assign", "will do", "by friday", "due"]
    private static let technicalTerms = ["bug", "api", "接口", "架构", "部署", "上线", "测试", "代码", "数据库", "性能", "并发", "缓存", "算法", "review", "merge", "deploy", "server", "latency", "crash", "回归", "联调", "灰度", "容器", "SDK", "crash"]
    private static let businessTerms = ["预算", "客户", "合同", "报价", "营收", "收入", "成本", "利润", "市场", "战略", "kpi", "roi", "季度", "budget", "revenue", "contract", "client", "customer", "quarter", "growth", "margin"]
    private static let clientTerms = ["客户", "贵司", "方案", "需求", "报价", "合同", "验收", "client", "customer", "proposal", "requirement", "quote", "pricing"]
    private static let standupTerms = ["昨天", "今天", "明天", "阻塞", "blocker", "yesterday", "today", "tomorrow", "blocked", "standup", "站会"]
    private static let brainstormTerms = ["想法", "创意", "点子", "脑暴", "头脑风暴", "假设", "如果……会", "idea", "brainstorm", "what if", "crazy", "workshop"]
    private static let formalMarkers = ["请", "您", "贵司", "特此", "审议", "兹", "各位领导"]
    private static let informalMarkers = ["咱们", "搞定", "挺好的", "ok", "好吧", "哈哈", "嗯哼", "那个啥"]

    public static func extract(session: MeetingSession) -> MeetingFeatures {
        let transcripts = session.topics.flatMap(\.transcripts)
        let fullText = transcripts.map(\.text).joined(separator: "\n")
        let lower = fullText.lowercased()
        let wordCount = max(fullText.count, 1)

        var f = MeetingFeatures()
        f.wordCount = wordCount
        if let end = session.endTime {
            f.durationMinutes = max(1, Int(end.timeIntervalSince(session.startTime) / 60))
        }

        f.decisionDensity = density(of: decisionKeywords, in: lower, wordCount: wordCount)
        f.actionDensity = density(of: actionKeywords, in: lower, wordCount: wordCount)
        f.technicalDensity = density(of: technicalTerms, in: lower, wordCount: wordCount)
        f.businessDensity = density(of: businessTerms, in: lower, wordCount: wordCount)

        let formal = density(of: formalMarkers, in: lower, wordCount: wordCount)
        let informal = density(of: informalMarkers, in: lower, wordCount: wordCount)
        f.formality = formal > informal * 1.5 ? .high : (informal > formal * 1.5 ? .low : .medium)

        let questionMarks = fullText.filter { $0 == "?" || $0 == "？" }.count
        let exclamations = fullText.filter { $0 == "!" || $0 == "！" }.count
        let intensityScore = Double(questionMarks + exclamations) / Double(wordCount) * 1000
        f.discussionIntensity = intensityScore > 8 ? .high : (intensityScore > 3 ? .medium : .low)

        for shot in session.screenshots {
            switch shot.contentType {
            case "slide": f.slideCount += 1
            case "chart": f.chartCount += 1
            case "whiteboard": f.whiteboardDetected = true
            default: break
            }
            f.slideDecisionCount += countJsonArrayItems(shot.slideDecisions)
            f.slideActionItemCount += countJsonArrayItems(shot.slideActionItems)
            f.slideKeyDateCount += countJsonArrayItems(shot.keyDates)
        }

        var scores: [String: Double] = [:]
        if f.technicalDensity > 0.05 { scores["technical_review"] = f.technicalDensity * 10 }
        if f.businessDensity > 0.05 && f.decisionDensity > 0.02 {
            scores["executive_meeting"] = (f.businessDensity + f.decisionDensity) * 8
        }
        let clientScore = density(of: clientTerms, in: lower, wordCount: wordCount)
        if clientScore > 0.03 { scores["client_meeting"] = clientScore * 9 }
        let standupScore = density(of: standupTerms, in: lower, wordCount: wordCount)
        if f.durationMinutes <= 30 && standupScore > 0.03 { scores["daily_standup"] = standupScore * 10 }
        let brainstormScore = density(of: brainstormTerms, in: lower, wordCount: wordCount)
        if brainstormScore > 0.03 { scores["brainstorming"] = brainstormScore * 9 }
        if f.whiteboardDetected { scores["brainstorming", default: 0] += 3 }
        if f.slideDecisionCount >= 2 { scores["executive_meeting", default: 0] += 2 }
        if f.chartCount >= 2 { scores["executive_meeting", default: 0] += 1; scores["project_weekly", default: 0] += 1 }
        if f.slideCount >= 5 { scores["project_weekly", default: 0] += 1.5; scores["technical_review", default: 0] += 1 }

        f.typeScores = scores
        if let best = scores.max(by: { $0.value < $1.value }), best.value > 0.5 {
            f.predictedType = best.key
            f.typeConfidence = min(best.value / 10, 1.0)
        }
        return f
    }

    private static func density(of keywords: [String], in text: String, wordCount: Int) -> Double {
        var hits = 0
        for kw in keywords {
            var searchStart = text.startIndex
            while let range = text.range(of: kw, range: searchStart..<text.endIndex) {
                hits += 1
                searchStart = range.upperBound
            }
        }
        return Double(hits) / Double(wordCount) * 100
    }

    private static func countJsonArrayItems(_ json: String?) -> Int {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return arr.count
    }
}
