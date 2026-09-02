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

public struct TemplateRecommendation: Sendable {
    public let templateId: String
    public let templateName: String
    public let score: Double
    public let matchReasons: [String]
    public let confidence: Double
}

public enum TemplateRecommender {
    public static func recommend(features: MeetingFeatures) -> (best: TemplateRecommendation, alternatives: [TemplateRecommendation]) {
        var scored: [TemplateRecommendation] = []

        for template in MinutesTemplateLibrary.all {
            var score = 0.0
            var reasons: [String] = []

            if template.suitableTypes.contains(features.predictedType) {
                score += 30
                reasons.append(tr("会议类型匹配：\(meetingTypeName(features.predictedType))", "Meeting type match: \(meetingTypeName(features.predictedType))"))
                if features.slideDecisionCount > 0 || features.chartCount > 0 {
                    score += 5
                    reasons.append(tr("画面内容支持该判断", "Screen content supports this"))
                }
            }

            if features.slideDecisionCount > 2 && template.expectedDecisionDensity == .high {
                score += 10
                reasons.append(tr("幻灯片中包含 \(features.slideDecisionCount) 个决策", "\(features.slideDecisionCount) decisions found on slides"))
            }
            if features.slideActionItemCount > 3 && template.expectedActionDensity == .high {
                score += 8
                reasons.append(tr("幻灯片中包含 \(features.slideActionItemCount) 个行动项", "\(features.slideActionItemCount) action items found on slides"))
            }

            if features.chartCount > 2 && template.keyFeatures.contains("data_tables") {
                score += 8
                reasons.append(tr("会议讨论了 \(features.chartCount) 个图表", "\(features.chartCount) charts discussed"))
            }
            if features.whiteboardDetected && template.id == "brainstorming" {
                score += 10
                reasons.append(tr("检测到白板讨论场景", "Whiteboard session detected"))
            }

            score += asrMatchScore(features: features, template: template, reasons: &reasons)

            if template.preferredDuration.contains(features.durationMinutes) {
                score += 10
            } else if features.durationMinutes > 0 {
                let dist = features.durationMinutes < template.preferredDuration.lowerBound
                    ? template.preferredDuration.lowerBound - features.durationMinutes
                    : features.durationMinutes - template.preferredDuration.upperBound
                score += max(0, 10 - Double(dist) / 6.0)
            }

            scored.append(TemplateRecommendation(
                templateId: template.id,
                templateName: template.name,
                score: score,
                matchReasons: reasons,
                confidence: multimodalConfidence(features: features, template: template)))
        }

        scored.sort { $0.score > $1.score }
        let best = scored.first ?? TemplateRecommendation(
            templateId: MinutesTemplateLibrary.fallbackId,
            templateName: MinutesTemplateLibrary.byId(nil).name,
            score: 0, matchReasons: [], confidence: 0.5)
        return (best, Array(scored.dropFirst().prefix(2)))
    }

    private static func asrMatchScore(features: MeetingFeatures, template: MinutesTemplate, reasons: inout [String]) -> Double {
        var score = 0.0
        let d = features.decisionDensity
        let a = features.actionDensity

        switch template.expectedDecisionDensity {
        case .high: if d > 0.15 { score += 8 } else if d > 0.08 { score += 4 }
        case .medium: if d > 0.05 && d <= 0.2 { score += 8 }
        case .low: if d <= 0.08 { score += 6 }
        }
        switch template.expectedActionDensity {
        case .high: if a > 0.2 { score += 8; reasons.append(tr("行动项密度高", "High action-item density")) } else if a > 0.1 { score += 4 }
        case .medium: if a > 0.08 && a <= 0.25 { score += 8 }
        case .low: if a <= 0.12 { score += 6 }
        }

        switch template.formality {
        case .high: if features.formality == .high { score += 5 }
        case .medium: if features.formality == .medium { score += 5 }
        case .low: if features.formality == .low { score += 5 }
        }

        if template.id == "technical_review" && features.technicalDensity > 0.05 {
            score += 4
            reasons.append(tr("技术术语密度 \(String(format: "%.1f", features.technicalDensity))%", "Technical term density \(String(format: "%.1f", features.technicalDensity))%"))
        }
        return min(score, 25)
    }

    private static func multimodalConfidence(features: MeetingFeatures, template: MinutesTemplate) -> Double {
        var evidence = 0.0
        if features.typeConfidence > 0.7 { evidence += 1 }
        if features.slideCount > 0 {
            let typeMatchesSlide = (features.predictedType == "technical_review" && features.slideDecisionCount + features.slideActionItemCount > 0)
                || (features.predictedType == "executive_meeting" && features.chartCount > 0)
                || (features.predictedType != "general_meeting" && features.slideCount >= 3)
            if typeMatchesSlide { evidence += 1 }
        }
        if features.chartCount > 0 { evidence += 0.5 }
        if features.whiteboardDetected && template.id == "brainstorming" { evidence += 1 }
        if template.suitableTypes.contains(features.predictedType) && features.slideCount > 2 { evidence += 0.5 }
        return min(evidence / 3.5, 1.0)
    }

    public static func meetingTypeName(_ type: String) -> String {
        switch type {
        case "technical_review": return tr("技术评审", "Technical Review")
        case "executive_meeting": return tr("高管/决策会议", "Executive Meeting")
        case "client_meeting": return tr("客户会议", "Client Meeting")
        case "daily_standup": return tr("每日站会", "Daily Standup")
        case "brainstorming": return tr("头脑风暴", "Brainstorming")
        case "project_weekly": return tr("项目例会", "Project Weekly")
        case "board_meeting": return tr("董事会", "Board Meeting")
        case "negotiation": return tr("商务谈判", "Negotiation")
        default: return tr("一般会议", "General Meeting")
        }
    }
}
