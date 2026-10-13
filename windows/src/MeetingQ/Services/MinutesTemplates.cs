using MeetingQ.Infrastructure;

namespace MeetingQ.Services;

/// <summary>
/// Minutes template library — line-by-line port of macOS
/// MeetingQCore/Services/MinutesTemplates.swift (same ids, same sections,
/// same bilingual roles/guidance) so both platforms share one spec.
/// </summary>
public enum MinutesSection
{
    CoreSummary, Decisions, ActionItems, Risks, OpenQuestions, TopicDetails, Highlights, NextSteps
}

public static class MinutesSectionExtensions
{
    public static string Title(this MinutesSection s) => s switch
    {
        MinutesSection.CoreSummary   => LocalizationManager.Get("MinSecCoreSummary"),
        MinutesSection.Decisions     => LocalizationManager.Get("MinSecDecisions"),
        MinutesSection.ActionItems   => LocalizationManager.Get("MinSecActionItems"),
        MinutesSection.Risks         => LocalizationManager.Get("MinSecRisks"),
        MinutesSection.OpenQuestions => LocalizationManager.Get("MinSecOpenQuestions"),
        MinutesSection.TopicDetails  => LocalizationManager.Get("MinSecTopicDetails"),
        MinutesSection.Highlights    => LocalizationManager.Get("MinSecHighlights"),
        MinutesSection.NextSteps     => LocalizationManager.Get("MinSecNextSteps"),
        _ => s.ToString()
    };
}

public enum Density { Low, Medium, High }

public sealed record MinutesTemplate(
    string Id,
    string NameZh, string NameEn,
    string[] SuitableTypes,
    Density Formality,
    Density ExpectedDecisionDensity,
    Density ExpectedActionDensity,
    int PreferredDurationMin, int PreferredDurationMax,
    string[] KeyFeatures,
    MinutesSection[] Sections,
    string RoleZh, string RoleEn,
    string ExtraGuidanceZh, string ExtraGuidanceEn)
{
    private static bool En => LocalizationManager.Instance.IsEnglish;

    public string Name          => En ? NameEn : NameZh;
    public string Role          => En ? RoleEn : RoleZh;
    public string ExtraGuidance => En ? ExtraGuidanceEn : ExtraGuidanceZh;

    public bool DurationInRange(int minutes) =>
        minutes >= PreferredDurationMin && minutes <= PreferredDurationMax;
}

public static class MinutesTemplateLibrary
{
    public const string FallbackId = "general_standard";

    public static readonly IReadOnlyList<MinutesTemplate> All = new[]
    {
        new MinutesTemplate(
            Id: "executive_business",
            NameZh: "高端商务版", NameEn: "Executive Business",
            SuitableTypes: new[] { "executive_meeting", "board_meeting", "client_meeting" },
            Formality: Density.High,
            ExpectedDecisionDensity: Density.High,
            ExpectedActionDensity: Density.Medium,
            PreferredDurationMin: 30, PreferredDurationMax: 240,
            KeyFeatures: new[] { "decision_rationale", "risk_register", "data_tables" },
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.Decisions, MinutesSection.ActionItems, MinutesSection.Risks, MinutesSection.OpenQuestions, MinutesSection.TopicDetails, MinutesSection.NextSteps },
            RoleZh: "你是一位资深的高管行政助理，拥有10年以上董事会秘书经验，擅长生成高端、专业、可执行的会议纪要。你的纪要文档将发送给公司管理层，必须体现专业性和权威性。",
            RoleEn: "You are a senior executive assistant with 10+ years of board-secretary experience, producing premium, professional, actionable meeting minutes for company leadership.",
            ExtraGuidanceZh: "每个决策必须包含决策依据（rationale）；风险须给出影响与建议应对；语气克制、权威、零口语化。",
            ExtraGuidanceEn: "Every decision must include its rationale; risks must state impact and suggested mitigation; tone must be restrained, authoritative, and free of colloquialisms."),

        new MinutesTemplate(
            Id: "technical_review",
            NameZh: "技术评审版", NameEn: "Technical Review",
            SuitableTypes: new[] { "technical_review" },
            Formality: Density.Medium,
            ExpectedDecisionDensity: Density.Medium,
            ExpectedActionDensity: Density.High,
            PreferredDurationMin: 15, PreferredDurationMax: 180,
            KeyFeatures: new[] { "data_tables", "risk_register", "acceptance_criteria" },
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.TopicDetails, MinutesSection.Decisions, MinutesSection.ActionItems, MinutesSection.Risks, MinutesSection.OpenQuestions },
            RoleZh: "你是一位资深技术项目经理，擅长从技术评审会议中提取关键技术决策、风险点和行动项。你生成的纪要被技术团队视为执行标准。",
            RoleEn: "You are a senior technical program manager extracting key technical decisions, risks, and action items from review meetings. Your minutes are treated as the team's execution standard.",
            ExtraGuidanceZh: "决策需写明技术方案选型及理由；行动项尽量给出验收标准；风险按严重程度排序。",
            ExtraGuidanceEn: "Decisions must state the chosen technical approach and why; action items should include acceptance criteria where possible; order risks by severity."),

        new MinutesTemplate(
            Id: "client_meeting",
            NameZh: "客户沟通版", NameEn: "Client Meeting",
            SuitableTypes: new[] { "client_meeting", "negotiation" },
            Formality: Density.High,
            ExpectedDecisionDensity: Density.Medium,
            ExpectedActionDensity: Density.High,
            PreferredDurationMin: 15, PreferredDurationMax: 180,
            KeyFeatures: new[] { "commitment_tracking", "requirements_summary" },
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.Decisions, MinutesSection.ActionItems, MinutesSection.OpenQuestions, MinutesSection.NextSteps },
            RoleZh: "你是一位资深商务助理，擅长从客户沟通会议中提取关键承诺、需求确认和后续行动。你生成的纪要具有准法律效力的严谨性。",
            RoleEn: "You are a senior business assistant extracting commitments, confirmed requirements, and follow-ups from client meetings, with near-legal rigor.",
            ExtraGuidanceZh: "明确区分我方承诺与客户承诺；所有待确认事项列入开放问题；避免任何歧义表述。",
            ExtraGuidanceEn: "Clearly separate our commitments from the client's; list all unconfirmed items under open questions; avoid any ambiguous wording."),

        new MinutesTemplate(
            Id: "project_weekly",
            NameZh: "项目周会版", NameEn: "Project Weekly",
            SuitableTypes: new[] { "project_weekly", "general_meeting" },
            Formality: Density.Medium,
            ExpectedDecisionDensity: Density.Medium,
            ExpectedActionDensity: Density.High,
            PreferredDurationMin: 15, PreferredDurationMax: 120,
            KeyFeatures: new[] { "progress_tracking", "risk_register" },
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.Highlights, MinutesSection.TopicDetails, MinutesSection.Decisions, MinutesSection.ActionItems, MinutesSection.Risks, MinutesSection.NextSteps },
            RoleZh: "你是一位高效的项目经理助理，擅长将项目例会变成可追踪的进度文档：进展、风险、下一步一目了然。",
            RoleEn: "You are an efficient PM assistant turning project syncs into trackable progress documents: progress, risks, and next steps at a glance.",
            ExtraGuidanceZh: "突出进度变化与风险预警；行动项必须有负责人；下周计划单独成节。",
            ExtraGuidanceEn: "Highlight progress deltas and risk warnings; every action item needs an owner; next week's plan gets its own section."),

        new MinutesTemplate(
            Id: "daily_standup",
            NameZh: "每日站会版", NameEn: "Daily Standup",
            SuitableTypes: new[] { "daily_standup" },
            Formality: Density.Low,
            ExpectedDecisionDensity: Density.Low,
            ExpectedActionDensity: Density.Medium,
            PreferredDurationMin: 3, PreferredDurationMax: 30,
            KeyFeatures: new[] { "blocker_tracking" },
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.ActionItems, MinutesSection.Risks },
            RoleZh: "你是一位敏捷团队助理，把每日站会压缩成极简记录：昨天完成、今天计划、阻塞问题。",
            RoleEn: "You are an agile team assistant compressing daily standups into minimal records: done yesterday, planned today, blockers.",
            ExtraGuidanceZh: "全文不超过300字；阻塞问题单独列出并@负责人；不写决策章节，除非确有决策。",
            ExtraGuidanceEn: "Keep the whole minutes under 300 words; list blockers separately with owners; omit the decisions section unless real decisions exist."),

        new MinutesTemplate(
            Id: "brainstorming",
            NameZh: "头脑风暴版", NameEn: "Brainstorming",
            SuitableTypes: new[] { "brainstorming" },
            Formality: Density.Low,
            ExpectedDecisionDensity: Density.Low,
            ExpectedActionDensity: Density.Low,
            PreferredDurationMin: 15, PreferredDurationMax: 180,
            KeyFeatures: new[] { "idea_clustering" },
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.Highlights, MinutesSection.TopicDetails, MinutesSection.Decisions, MinutesSection.ActionItems, MinutesSection.NextSteps },
            RoleZh: "你是一位创意工作坊引导师，擅长把发散讨论整理成结构化的创意清单：分类、亮点、待验证想法。",
            RoleEn: "You are a creative workshop facilitator turning divergent discussions into structured idea lists: clusters, highlights, ideas to validate.",
            ExtraGuidanceZh: "保留创意的多样性，不急于收敛；亮点想法列入要点；后续验证计划列入下一步。",
            ExtraGuidanceEn: "Preserve idea diversity without premature convergence; put standout ideas in highlights; put validation plans in next steps."),

        new MinutesTemplate(
            Id: "general_standard",
            NameZh: "通用标准版", NameEn: "General Standard",
            SuitableTypes: new[] { "general_meeting" },
            Formality: Density.Medium,
            ExpectedDecisionDensity: Density.Medium,
            ExpectedActionDensity: Density.Medium,
            PreferredDurationMin: 5, PreferredDurationMax: 240,
            KeyFeatures: Array.Empty<string>(),
            Sections: new[] { MinutesSection.CoreSummary, MinutesSection.TopicDetails, MinutesSection.Decisions, MinutesSection.ActionItems, MinutesSection.OpenQuestions, MinutesSection.NextSteps },
            RoleZh: "你是一位专业的会议纪要助手，生成结构清晰、结论明确的会议纪要。",
            RoleEn: "You are a professional meeting-minutes assistant producing clearly structured, conclusion-focused minutes.",
            ExtraGuidanceZh: "", ExtraGuidanceEn: ""),
    };

    public static MinutesTemplate ById(string? id)
    {
        if (id is not null)
        {
            foreach (var t in All)
                if (t.Id == id) return t;
        }
        return All.First(t => t.Id == FallbackId);
    }

    public static string? DisplayName(string? id)
        => id is null ? null : All.FirstOrDefault(t => t.Id == id)?.Name;
}
