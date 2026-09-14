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

public struct QualityAssessment: Sendable {
    public let score: Int
    public let confidence: String
    public let issues: [String]
    public let needsHumanReview: Bool
}

public enum MinutesQualityAssessor {
    public static func assess(minutes: StructuredMinutes,
                              topics: [Topic],
                              template: MinutesTemplate) -> QualityAssessment {
        var issues: [String] = []
        var score = 100

        let transcriptDecisions = topics.flatMap(\.decisions)
        if !transcriptDecisions.isEmpty {
            let recalled = transcriptDecisions.filter { d in
                minutes.decisions.contains { overlap($0.text, d.decisionText) >= 0.5 }
            }
            let recall = Double(recalled.count) / Double(transcriptDecisions.count)
            if recall < 0.8 {
                score -= 15
                issues.append(tr("可能遗漏决策：转写中提取到 \(transcriptDecisions.count) 个决策，纪要中仅 \(minutes.decisions.count) 个",
                                 "Possible missing decisions: \(transcriptDecisions.count) found in transcript, only \(minutes.decisions.count) in minutes"))
            } else if recall < 0.9 {
                score -= 5
                issues.append(tr("决策提取基本完整，可能有少量遗漏", "Decision extraction mostly complete, minor omissions possible"))
            }
        }

        let transcriptActions = topics.flatMap(\.actionItems)
        if !transcriptActions.isEmpty {
            let recalled = transcriptActions.filter { a in
                minutes.actionItems.contains { overlap($0.task, a.task) >= 0.5 }
            }
            let recall = Double(recalled.count) / Double(transcriptActions.count)
            if recall < 0.7 {
                score -= 10
                issues.append(tr("行动项召回率偏低（\(Int(recall * 100))%）", "Low action-item recall (\(Int(recall * 100))%)"))
            }
        }

        let malformed = minutes.actionItems.filter { $0.owner.trimmingCharacters(in: .whitespaces).isEmpty || $0.deadline == nil }
        if !minutes.actionItems.isEmpty && malformed.count > minutes.actionItems.count / 5 {
            score -= 10
            issues.append(tr("部分行动项缺少负责人或截止时间", "Some action items lack an owner or deadline"))
        }

        var missing: [String] = []
        for section in template.sections {
            switch section {
            case .coreSummary:
                if minutes.summary.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    missing.append(section.title)
                }
            case .decisions:
                if minutes.decisions.isEmpty && !transcriptDecisions.isEmpty { missing.append(section.title) }
            case .actionItems:
                if minutes.actionItems.isEmpty && !transcriptActions.isEmpty { missing.append(section.title) }
            case .risks:
                if template.expectedDecisionDensity == .high && minutes.risks.isEmpty { missing.append(section.title) }
            case .topicDetails:
                if minutes.topicDetails.isEmpty && topics.count > 1 { missing.append(section.title) }
            case .highlights, .openQuestions, .nextSteps:
                break
            }
        }
        if !missing.isEmpty {
            score -= 10
            issues.append(tr("模板符合度不足：缺少 \(missing.joined(separator: "、"))",
                             "Template compliance issue: missing \(missing.joined(separator: ", "))"))
        }

        let summary = minutes.summary
        if summary.contains("作为AI") || summary.contains("as an AI") || summary.contains("```") {
            score -= 6
            issues.append(tr("语言质量问题：包含模型自述或残留标记", "Language quality issue: model self-reference or leftover markup"))
        }

        score = max(0, score)
        let confidence = score >= 90 ? "High" : (score >= 70 ? "Medium" : "Low")
        return QualityAssessment(score: score,
                                 confidence: confidence,
                                 issues: issues,
                                 needsHumanReview: score < 70)
    }

    private static func overlap(_ a: String, _ b: String) -> Double {
        let ta = bigrams(a)
        let tb = bigrams(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        return Double(inter) / Double(min(ta.count, tb.count))
    }

    static func bigrams(_ s: String) -> Set<String> {
        let normalized = s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let chars = Array(normalized)
        guard chars.count >= 2 else { return normalized.isEmpty ? [] : [normalized] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i...i + 1]))
        }
        return out
    }
}
