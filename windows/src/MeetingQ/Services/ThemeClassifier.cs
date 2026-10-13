using System.Text.Json;
using MeetingQ.Data;
using MeetingQ.Infrastructure;
using MeetingQ.Models;
using MeetingQ.Services.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace MeetingQ.Services;

/// <summary>
/// Cross-meeting theme classification — port of macOS ThemeClassifier.swift.
/// Same thresholds (attach 0.45 / candidate 0.15 / 90-day decay ×0.5),
/// same LLM decision JSON, same keyword merge rules.
/// </summary>
public static class ThemeClassifier
{
    private const double AttachThreshold    = 0.45;
    private const double CandidateThreshold = 0.15;
    private static readonly TimeSpan NinetyDays = TimeSpan.FromDays(90);

    private sealed record SessionSignature(string Title, string Text, List<string> Keywords);

    private static SessionSignature SignatureFor(MeetingSession session, IReadOnlyList<Topic> topics)
    {
        var topicTitles = string.Join(" ", topics.Select(t => t.Title));
        var summary = session.Summary ?? "";
        var decisions = string.Join(" ", topics.SelectMany(t => t.Decisions).Select(d => d.DecisionText));
        var text = string.Join(" ", new[] { session.Title ?? "", topicTitles, summary, decisions });
        return new SessionSignature(session.Title ?? "", text, TopKeywords(text));
    }

    /// <summary>Classifies a finished session into a theme (existing or newly created).
    /// Returns the theme id, or null when the session has no usable content.</summary>
    public static async Task<int?> ClassifyAsync(AppDbContext db, MeetingSession session,
        IReadOnlyList<Topic> topics, ILlmService llm, CancellationToken ct = default)
    {
        var themes = await db.MeetingThemes.Where(t => !t.IsArchived).ToListAsync(ct);
        var sig = SignatureFor(session, topics);
        if (string.IsNullOrWhiteSpace(sig.Text)) return null;

        var candidates = new List<(MeetingTheme Theme, double Score)>();
        foreach (var theme in themes)
        {
            var score = Similarity(sig.Text, theme.Name + " " + string.Join(" ", ReadKeywords(theme)));
            // 90-day decay: meetings far from the theme's latest session score half
            var latest = await db.Sessions
                .Where(s => s.ThemeId == theme.ThemeId)
                .OrderByDescending(s => s.StartTime)
                .Select(s => (DateTime?)s.StartTime)
                .FirstOrDefaultAsync(ct);
            if (latest.HasValue && session.StartTime - latest.Value > NinetyDays)
                score *= 0.5;
            if (score > CandidateThreshold)
                candidates.Add((theme, score));
        }
        candidates.Sort((a, b) => b.Score.CompareTo(a.Score));
        var topCandidates = candidates.Take(5).ToList();

        var llmDecision = await LlmClassifyAsync(sig, topCandidates, llm, ct);
        if (llmDecision is not null)
            return await ApplyAsync(db, llmDecision, sig, ct);

        if (topCandidates.Count > 0 && topCandidates[0].Score > AttachThreshold)
        {
            await MergeKeywordsAsync(db, topCandidates[0].Theme, sig.Keywords, ct);
            return topCandidates[0].Theme.ThemeId;
        }
        var created = await CreateThemeAsync(db, sig, ct: ct);
        return created.ThemeId;
    }

    private sealed record LlmDecision(string Action, int? ThemeId, string? NewName, List<string> Keywords);

    private static async Task<LlmDecision?> LlmClassifyAsync(SessionSignature sig,
        List<(MeetingTheme Theme, double Score)> candidates, ILlmService llm, CancellationToken ct)
    {
        var en = LocalizationManager.Instance.IsEnglish;
        var candidateDesc = string.Join("\n", candidates.Select((c, i) =>
            $"{i + 1}. id={c.Theme.ThemeId} | {c.Theme.Name} | keywords: {string.Join(", ", ReadKeywords(c.Theme))}"));

        var prompt = en
            ? "Decide whether the meeting below belongs to an existing theme (an ongoing project/activity spanning multiple meetings) or needs a new theme.\n\n"
              + $"Meeting:\nTitle: {sig.Title}\nContent signature: {sig.Text[..Math.Min(800, sig.Text.Length)]}\n\n"
              + $"Candidate themes:\n{(candidateDesc.Length == 0 ? "(none)" : candidateDesc)}\n"
              + "Rules: attach only when the meeting clearly continues the same project/activity; otherwise create a new theme. New theme names must follow \"[project/product] + [stage/activity]\", e.g. \"Product Launch Prep\". Meetings over 90 days apart usually need a new theme.\n"
              + "Return JSON only: {\"action\":\"attach\" or \"create\",\"theme_id\":number or null,\"new_theme_name\":\"name when creating, else null\",\"keywords\":[\"3-5 keywords\"]}"
            : "判断下面这场会议属于某个已有主题（跨多次会议的同一项目/活动），还是需要新建主题。\n\n"
              + $"会议：\n标题：{sig.Title}\n内容签名：{sig.Text[..Math.Min(800, sig.Text.Length)]}\n\n"
              + $"候选主题：\n{(candidateDesc.Length == 0 ? "（无）" : candidateDesc)}\n"
              + "规则：仅当会议明显延续同一项目/活动时归入已有主题，否则新建。新主题命名遵循「项目/产品名 + 阶段/活动类型」，如\"产品上线筹备\"。相隔超过90天的会议通常应新建主题。\n"
              + "只返回JSON：{\"action\":\"attach\" 或 \"create\",\"theme_id\":数字或null,\"new_theme_name\":\"新建时的名称，否则null\",\"keywords\":[\"3-5个关键词\"]}";

        string response;
        try { response = await llm.AnalyzeAsync(prompt, ct); }
        catch { return null; }

        var text = response;
        var s = text.IndexOf('{');
        var e = text.LastIndexOf('}');
        if (s < 0 || e <= s) return null;
        text = text[s..(e + 1)];

        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            if (!root.TryGetProperty("action", out var actionEl) || actionEl.ValueKind != JsonValueKind.String)
                return null;
            int? themeId = null;
            if (root.TryGetProperty("theme_id", out var idEl))
            {
                if (idEl.ValueKind == JsonValueKind.Number && idEl.TryGetInt32(out var n)) themeId = n;
                else if (idEl.ValueKind == JsonValueKind.String && int.TryParse(idEl.GetString(), out var m)) themeId = m;
            }
            var keywords = new List<string>();
            if (root.TryGetProperty("keywords", out var kwEl) && kwEl.ValueKind == JsonValueKind.Array)
                foreach (var k in kwEl.EnumerateArray())
                    if (k.ValueKind == JsonValueKind.String && k.GetString() is { } ks)
                        keywords.Add(ks);
            return new LlmDecision(actionEl.GetString()!, themeId,
                root.TryGetProperty("new_theme_name", out var nn) && nn.ValueKind == JsonValueKind.String
                    ? nn.GetString() : null, keywords);
        }
        catch { return null; }
    }

    private static async Task<int> ApplyAsync(AppDbContext db, LlmDecision decision,
        SessionSignature sig, CancellationToken ct)
    {
        if (decision.Action == "attach" && decision.ThemeId.HasValue)
        {
            var theme = await db.MeetingThemes.FindAsync(new object?[] { decision.ThemeId.Value }, ct);
            if (theme is not null)
            {
                await MergeKeywordsAsync(db, theme, sig.Keywords.Concat(decision.Keywords).ToList(), ct);
                return theme.ThemeId;
            }
        }
        var name = decision.NewName?.Trim();
        var created = await CreateThemeAsync(db, sig,
            name: string.IsNullOrEmpty(name) ? null : name,
            extraKeywords: decision.Keywords, ct: ct);
        return created.ThemeId;
    }

    private static async Task<MeetingTheme> CreateThemeAsync(AppDbContext db, SessionSignature sig,
        string? name = null, List<string>? extraKeywords = null, CancellationToken ct = default)
    {
        string themeName;
        if (!string.IsNullOrEmpty(name) && name.Length <= 30)
            themeName = name;
        else if (sig.Keywords.Count > 0)
            themeName = string.Join(" ", sig.Keywords.Take(2));
        else
            themeName = sig.Title;

        var keywords = sig.Keywords.Concat(extraKeywords ?? new List<string>()).Distinct().Take(8).ToList();
        var theme = new MeetingTheme
        {
            Name = themeName,
            KeywordsJson = JsonSerializer.Serialize(keywords),
            CreatedAt = DateTime.Now
        };
        db.MeetingThemes.Add(theme);
        await db.SaveChangesAsync(ct);
        return theme;
    }

    private static async Task MergeKeywordsAsync(AppDbContext db, MeetingTheme theme,
        List<string> newKeywords, CancellationToken ct)
    {
        var merged = ReadKeywords(theme).Concat(newKeywords).Distinct().Take(10).ToList();
        var mergedJson = JsonSerializer.Serialize(merged);
        if (mergedJson != theme.KeywordsJson)
        {
            theme.KeywordsJson = mergedJson;
            await db.SaveChangesAsync(ct);
        }
    }

    public static List<string> ReadKeywords(MeetingTheme theme)
    {
        try
        {
            return JsonSerializer.Deserialize<List<string>>(theme.KeywordsJson) ?? new List<string>();
        }
        catch { return new List<string>(); }
    }

    /// <summary>Jaccard similarity over bigram sets — same as macOS.</summary>
    public static double Similarity(string a, string b)
    {
        var ta = MinutesQualityAssessor.Bigrams(a);
        var tb = MinutesQualityAssessor.Bigrams(b);
        if (ta.Count == 0 || tb.Count == 0) return 0;
        var inter = ta.Intersect(tb).Count();
        var union = ta.Union(tb).Count();
        return union == 0 ? 0 : (double)inter / union;
    }

    public static List<string> TopKeywords(string text)
    {
        var stop = new HashSet<string> { "我们", "你们", "他们", "这个", "那个", "就是", "可以", "什么", "怎么", "现在", "然后", "因为", "所以", "但是", "如果", "没有", "the", "and", "for", "that", "this", "with", "have", "will" };
        var counts = new Dictionary<string, int>();
        var chars = text.ToLowerInvariant().Where(c => !char.IsPunctuation(c) && !char.IsWhiteSpace(c)).ToArray();
        if (chars.Length < 2) return new List<string>();
        var i = 0;
        while (i < chars.Length - 1)
        {
            var len = Math.Min(4, chars.Length - i);
            for (var l = Math.Min(4, len); l >= 2; l--)
            {
                var word = new string(chars, i, l);
                if (!stop.Contains(word))
                    counts[word] = counts.GetValueOrDefault(word) + 1;
            }
            i += 1;
        }
        return counts.Where(kv => kv.Value >= 2 && kv.Key.Length >= 2)
            .OrderByDescending(kv => kv.Value)
            .Take(6)
            .Select(kv => kv.Key)
            .ToList();
    }
}

/// <summary>
/// Groups repeated action items across meetings of one theme — port of macOS
/// CrossMeetingActionTracker. Same 0.6 similarity threshold, same recency ordering.
/// </summary>
public static class CrossMeetingActionTracker
{
    public sealed record TrackedAction(ActionItem Representative, List<ActionItem> Occurrences, int MentionCount);

    public static List<TrackedAction> Group(IReadOnlyList<ActionItem> items)
    {
        var groups = new List<List<ActionItem>>();
        foreach (var item in items)
        {
            var placed = false;
            foreach (var g in groups)
            {
                if (g.Count > 0 && ThemeClassifier.Similarity(g[0].Task, item.Task) > 0.6)
                {
                    g.Add(item);
                    placed = true;
                    break;
                }
            }
            if (!placed) groups.Add(new List<ActionItem> { item });
        }
        return groups
            .Select(g =>
            {
                var sorted = g.OrderBy(a => a.Timestamp).ToList();
                return new TrackedAction(sorted[^1], sorted, g.Count);
            })
            .OrderByDescending(t => t.Representative.Timestamp)
            .ToList();
    }
}
