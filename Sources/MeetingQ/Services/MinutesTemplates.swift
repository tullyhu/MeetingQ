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

public enum MinutesSection: String, CaseIterable, Sendable {
    case coreSummary, decisions, actionItems, risks, openQuestions, topicDetails, highlights, nextSteps

    public var title: String {
        switch self {
        case .coreSummary: return tr("核心摘要", "Executive Summary")
        case .decisions: return tr("关键决策", "Key Decisions")
        case .actionItems: return tr("行动项", "Action Items")
        case .risks: return tr("风险与待确认", "Risks & Open Risks")
        case .openQuestions: return tr("待确认问题", "Open Questions")
        case .topicDetails: return tr("议程详情", "Agenda Details")
        case .highlights: return tr("要点回顾", "Key Highlights")
        case .nextSteps: return tr("后续计划", "Next Steps")
        }
    }
}

public struct MinutesTemplate: Sendable {
    public enum Density: String, Sendable { case low, medium, high }

    public let id: String
    public let nameZh: String
    public let nameEn: String
    public let suitableTypes: [String]
    public let formality: Density
    public let expectedDecisionDensity: Density
    public let expectedActionDensity: Density
    public let preferredDuration: ClosedRange<Int>
    public let keyFeatures: [String]
    public let sections: [MinutesSection]
    public let roleZh: String
    public let roleEn: String
    public let extraGuidanceZh: String
    public let extraGuidanceEn: String

    public var name: String { tr(nameZh, nameEn) }
    public var role: String { tr(roleZh, roleEn) }
    public var extraGuidance: String { tr(extraGuidanceZh, extraGuidanceEn) }
}

public enum MinutesTemplateLibrary {
    public static let fallbackId = "general_standard"

    public static let all: [MinutesTemplate] = [
        MinutesTemplate(
            id: "executive_business",
            nameZh: "高端商务版",
            nameEn: "Executive Business",
            suitableTypes: ["executive_meeting", "board_meeting", "client_meeting"],
            formality: .high,
            expectedDecisionDensity: .high,
            expectedActionDensity: .medium,
            preferredDuration: 30...240,
            keyFeatures: ["decision_rationale", "risk_register", "data_tables"],
            sections: [.coreSummary, .decisions, .actionItems, .risks, .openQuestions, .topicDetails, .nextSteps],
            roleZh: "你是一位资深的高管行政助理，拥有10年以上董事会秘书经验，擅长生成高端、专业、可执行的会议纪要。你的纪要文档将发送给公司管理层，必须体现专业性和权威性。",
            roleEn: "You are a senior executive assistant with 10+ years of board-secretary experience, producing premium, professional, actionable meeting minutes for company leadership.",
            extraGuidanceZh: "每个决策必须包含决策依据（rationale）；风险须给出影响与建议应对；语气克制、权威、零口语化。",
            extraGuidanceEn: "Every decision must include its rationale; risks must state impact and suggested mitigation; tone must be restrained, authoritative, and free of colloquialisms."
        ),
        MinutesTemplate(
            id: "technical_review",
            nameZh: "技术评审版",
            nameEn: "Technical Review",
            suitableTypes: ["technical_review"],
            formality: .medium,
            expectedDecisionDensity: .medium,
            expectedActionDensity: .high,
            preferredDuration: 15...180,
            keyFeatures: ["data_tables", "risk_register", "acceptance_criteria"],
            sections: [.coreSummary, .topicDetails, .decisions, .actionItems, .risks, .openQuestions],
            roleZh: "你是一位资深技术项目经理，擅长从技术评审会议中提取关键技术决策、风险点和行动项。你生成的纪要被技术团队视为执行标准。",
            roleEn: "You are a senior technical program manager extracting key technical decisions, risks, and action items from review meetings. Your minutes are treated as the team's execution standard.",
            extraGuidanceZh: "决策需写明技术方案选型及理由；行动项尽量给出验收标准；风险按严重程度排序。",
            extraGuidanceEn: "Decisions must state the chosen technical approach and why; action items should include acceptance criteria where possible; order risks by severity."
        ),
        MinutesTemplate(
            id: "client_meeting",
            nameZh: "客户沟通版",
            nameEn: "Client Meeting",
            suitableTypes: ["client_meeting", "negotiation"],
            formality: .high,
            expectedDecisionDensity: .medium,
            expectedActionDensity: .high,
            preferredDuration: 15...180,
            keyFeatures: ["commitment_tracking", "requirements_summary"],
            sections: [.coreSummary, .decisions, .actionItems, .openQuestions, .nextSteps],
            roleZh: "你是一位资深商务助理，擅长从客户沟通会议中提取关键承诺、需求确认和后续行动。你生成的纪要具有准法律效力的严谨性。",
            roleEn: "You are a senior business assistant extracting commitments, confirmed requirements, and follow-ups from client meetings, with near-legal rigor.",
            extraGuidanceZh: "明确区分我方承诺与客户承诺；所有待确认事项列入开放问题；避免任何歧义表述。",
            extraGuidanceEn: "Clearly separate our commitments from the client's; list all unconfirmed items under open questions; avoid any ambiguous wording."
        ),
        MinutesTemplate(
            id: "project_weekly",
            nameZh: "项目周会版",
            nameEn: "Project Weekly",
            suitableTypes: ["project_weekly", "general_meeting"],
            formality: .medium,
            expectedDecisionDensity: .medium,
            expectedActionDensity: .high,
            preferredDuration: 15...120,
            keyFeatures: ["progress_tracking", "risk_register"],
            sections: [.coreSummary, .highlights, .topicDetails, .decisions, .actionItems, .risks, .nextSteps],
            roleZh: "你是一位高效的项目经理助理，擅长将项目例会变成可追踪的进度文档：进展、风险、下一步一目了然。",
            roleEn: "You are an efficient PM assistant turning project syncs into trackable progress documents: progress, risks, and next steps at a glance.",
            extraGuidanceZh: "突出进度变化与风险预警；行动项必须有负责人；下周计划单独成节。",
            extraGuidanceEn: "Highlight progress deltas and risk warnings; every action item needs an owner; next week's plan gets its own section."
        ),
        MinutesTemplate(
            id: "daily_standup",
            nameZh: "每日站会版",
            nameEn: "Daily Standup",
            suitableTypes: ["daily_standup"],
            formality: .low,
            expectedDecisionDensity: .low,
            expectedActionDensity: .medium,
            preferredDuration: 3...30,
            keyFeatures: ["blocker_tracking"],
            sections: [.coreSummary, .actionItems, .risks],
            roleZh: "你是一位敏捷团队助理，把每日站会压缩成极简记录：昨天完成、今天计划、阻塞问题。",
            roleEn: "You are an agile team assistant compressing daily standups into minimal records: done yesterday, planned today, blockers.",
            extraGuidanceZh: "全文不超过300字；阻塞问题单独列出并@负责人；不写决策章节，除非确有决策。",
            extraGuidanceEn: "Keep the whole minutes under 300 words; list blockers separately with owners; omit the decisions section unless real decisions exist."
        ),
        MinutesTemplate(
            id: "brainstorming",
            nameZh: "头脑风暴版",
            nameEn: "Brainstorming",
            suitableTypes: ["brainstorming"],
            formality: .low,
            expectedDecisionDensity: .low,
            expectedActionDensity: .low,
            preferredDuration: 15...180,
            keyFeatures: ["idea_clustering"],
            sections: [.coreSummary, .highlights, .topicDetails, .decisions, .actionItems, .nextSteps],
            roleZh: "你是一位创意工作坊引导师，擅长把发散讨论整理成结构化的创意清单：分类、亮点、待验证想法。",
            roleEn: "You are a creative workshop facilitator turning divergent discussions into structured idea lists: clusters, highlights, ideas to validate.",
            extraGuidanceZh: "保留创意的多样性，不急于收敛；亮点想法列入要点；后续验证计划列入下一步。",
            extraGuidanceEn: "Preserve idea diversity without premature convergence; put standout ideas in highlights; put validation plans in next steps."
        ),
        MinutesTemplate(
            id: "general_standard",
            nameZh: "通用标准版",
            nameEn: "General Standard",
            suitableTypes: ["general_meeting"],
            formality: .medium,
            expectedDecisionDensity: .medium,
            expectedActionDensity: .medium,
            preferredDuration: 5...240,
            keyFeatures: [],
            sections: [.coreSummary, .topicDetails, .decisions, .actionItems, .openQuestions, .nextSteps],
            roleZh: "你是一位专业的会议纪要助手，生成结构清晰、结论明确的会议纪要。",
            roleEn: "You are a professional meeting-minutes assistant producing clearly structured, conclusion-focused minutes.",
            extraGuidanceZh: "",
            extraGuidanceEn: ""
        ),
    ]

    public static func byId(_ id: String?) -> MinutesTemplate {
        guard let id, let t = all.first(where: { $0.id == id }) else {
            return all.first { $0.id == fallbackId }!
        }
        return t
    }

    public static func displayName(for id: String?) -> String? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })?.name
    }
}
