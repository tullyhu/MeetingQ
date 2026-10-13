using System.Text.Json;
using MeetingQ.Models;

namespace MeetingQ.Services;

/// <summary>
/// Meeting feature extraction — port of macOS MeetingFeatureExtractor.swift.
/// Windows screenshots carry ContentType but not slide-level decision/action
/// extraction, so slideDecisionCount / slideActionItemCount / slideKeyDateCount
/// stay 0 and the recommender degrades gracefully to transcript-only signals.
/// </summary>
public sealed class MeetingFeatures
{
    public string PredictedType { get; set; } = "general_meeting";
    public double TypeConfidence { get; set; } = 0.5;
    public Dictionary<string, double> TypeScores { get; set; } = new();
    public Density Formality { get; set; } = Density.Medium;
    public double DecisionDensity { get; set; }
    public double ActionDensity { get; set; }
    public double TechnicalDensity { get; set; }
    public double BusinessDensity { get; set; }
    public Density DiscussionIntensity { get; set; } = Density.Low;
    public int DurationMinutes { get; set; }
    public int WordCount { get; set; }
    public int SlideCount { get; set; }
    public int ChartCount { get; set; }
    public bool WhiteboardDetected { get; set; }
    public int SlideDecisionCount { get; set; }
    public int SlideActionItemCount { get; set; }
    public int SlideKeyDateCount { get; set; }
}

public static class MeetingFeatureExtractor
{
    private static readonly string[] DecisionKeywords = { "决定", "确定", "同意", "通过", "批准", "就这么定", "拍板", "decide", "decided", "decision", "agree", "agreed", "approve", "approved", "confirm", "confirmed", "finalize" };
    private static readonly string[] ActionKeywords   = { "需要", "负责", "跟进", "完成", "提交", "我来", "你来做", "落实", "安排", "todo", "action item", "follow up", "owner", "deadline", "assign", "will do", "by friday", "due" };
    private static readonly string[] TechnicalTerms   = { "bug", "api", "接口", "架构", "部署", "上线", "测试", "代码", "数据库", "性能", "并发", "缓存", "算法", "review", "merge", "deploy", "server", "latency", "crash", "回归", "联调", "灰度", "容器", "sdk" };
    private static readonly string[] BusinessTerms    = { "预算", "客户", "合同", "报价", "营收", "收入", "成本", "利润", "市场", "战略", "kpi", "roi", "季度", "budget", "revenue", "contract", "client", "customer", "quarter", "growth", "margin" };
    private static readonly string[] ClientTerms      = { "客户", "贵司", "方案", "需求", "报价", "合同", "验收", "client", "customer", "proposal", "requirement", "quote", "pricing" };
    private static readonly string[] StandupTerms     = { "昨天", "今天", "明天", "阻塞", "blocker", "yesterday", "today", "tomorrow", "blocked", "standup", "站会" };
    private static readonly string[] BrainstormTerms  = { "想法", "创意", "点子", "脑暴", "头脑风暴", "假设", "如果……会", "idea", "brainstorm", "what if", "crazy", "workshop" };
    private static readonly string[] FormalMarkers    = { "请", "您", "贵司", "特此", "审议", "兹", "各位领导" };
    private static readonly string[] InformalMarkers  = { "咱们", "搞定", "挺好的", "ok", "好吧", "哈哈", "嗯哼", "那个啥" };

    public static MeetingFeatures Extract(MeetingSession session, IReadOnlyList<Topic> topics,
        IReadOnlyList<Screenshot> screenshots)
    {
        var fullText = string.Join("\n", topics.SelectMany(t => t.Transcripts).Select(t => t.Text));
        var lower = fullText.ToLowerInvariant();
        var wordCount = Math.Max(fullText.Length, 1);

        var f = new MeetingFeatures { WordCount = wordCount };
        if (session.EndTime.HasValue)
            f.DurationMinutes = Math.Max(1, (int)((session.EndTime.Value - session.StartTime).TotalMinutes));

        f.DecisionDensity  = DensityOf(DecisionKeywords, lower, wordCount);
        f.ActionDensity    = DensityOf(ActionKeywords, lower, wordCount);
        f.TechnicalDensity = DensityOf(TechnicalTerms, lower, wordCount);
        f.BusinessDensity  = DensityOf(BusinessTerms, lower, wordCount);

        var formal   = DensityOf(FormalMarkers, lower, wordCount);
        var informal = DensityOf(InformalMarkers, lower, wordCount);
        f.Formality = formal > informal * 1.5 ? Density.High
                    : informal > formal * 1.5 ? Density.Low : Density.Medium;

        var questionMarks = fullText.Count(c => c is '?' or '？');
        var exclamations  = fullText.Count(c => c is '!' or '！');
        var intensityScore = (double)(questionMarks + exclamations) / wordCount * 1000;
        f.DiscussionIntensity = intensityScore > 8 ? Density.High : intensityScore > 3 ? Density.Medium : Density.Low;

        foreach (var shot in screenshots)
        {
            switch (shot.ContentType)
            {
                case "slide":      f.SlideCount++; break;
                case "chart":      f.ChartCount++; break;
                case "whiteboard": f.WhiteboardDetected = true; break;
            }
        }

        var scores = new Dictionary<string, double>();
        if (f.TechnicalDensity > 0.05) scores["technical_review"] = f.TechnicalDensity * 10;
        if (f.BusinessDensity > 0.05 && f.DecisionDensity > 0.02)
            scores["executive_meeting"] = (f.BusinessDensity + f.DecisionDensity) * 8;
        var clientScore = DensityOf(ClientTerms, lower, wordCount);
        if (clientScore > 0.03) scores["client_meeting"] = clientScore * 9;
        var standupScore = DensityOf(StandupTerms, lower, wordCount);
        if (f.DurationMinutes <= 30 && standupScore > 0.03) scores["daily_standup"] = standupScore * 10;
        var brainstormScore = DensityOf(BrainstormTerms, lower, wordCount);
        if (brainstormScore > 0.03) scores["brainstorming"] = brainstormScore * 9;
        if (f.WhiteboardDetected) scores["brainstorming"] = scores.GetValueOrDefault("brainstorming") + 3;
        if (f.SlideDecisionCount >= 2) scores["executive_meeting"] = scores.GetValueOrDefault("executive_meeting") + 2;
        if (f.ChartCount >= 2)
        {
            scores["executive_meeting"] = scores.GetValueOrDefault("executive_meeting") + 1;
            scores["project_weekly"]    = scores.GetValueOrDefault("project_weekly") + 1;
        }
        if (f.SlideCount >= 5)
        {
            scores["project_weekly"]    = scores.GetValueOrDefault("project_weekly") + 1.5;
            scores["technical_review"]  = scores.GetValueOrDefault("technical_review") + 1;
        }

        f.TypeScores = scores;
        if (scores.Count > 0)
        {
            var best = scores.MaxBy(kv => kv.Value);
            if (best.Value > 0.5)
            {
                f.PredictedType   = best.Key;
                f.TypeConfidence  = Math.Min(best.Value / 10, 1.0);
            }
        }
        return f;
    }

    private static double DensityOf(string[] keywords, string text, int wordCount)
    {
        var hits = 0;
        foreach (var kw in keywords)
        {
            var idx = 0;
            while ((idx = text.IndexOf(kw, idx, StringComparison.Ordinal)) >= 0)
            {
                hits++;
                idx += kw.Length;
            }
        }
        return (double)hits / wordCount * 100;
    }

    /// <summary>Counts items in a JSON array string; 0 when null/invalid. Kept for parity with macOS.</summary>
    public static int CountJsonArrayItems(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return 0;
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind == JsonValueKind.Array ? doc.RootElement.GetArrayLength() : 0;
        }
        catch { return 0; }
    }
}
