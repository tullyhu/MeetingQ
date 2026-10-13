using MeetingQ.Models;
using MeetingQ.Services;
using Xunit;

namespace MeetingQ.Tests;

/// <summary>
/// Mirrors the macOS MeetingQCore specs for the minutes template pipeline and
/// cross-meeting theme logic (same thresholds, same weights, same parsing rules).
/// </summary>
public class MinutesAndThemesTests
{
    // ── TemplateRecommender ────────────────────────────────────────────────

    [Fact]
    public void Recommender_PrefersStandupForShortStandupLikeMeeting()
    {
        var f = new MeetingFeatures { PredictedType = "daily_standup", DurationMinutes = 10 };
        var (best, _) = TemplateRecommender.Recommend(f);
        Assert.Equal("daily_standup", best.TemplateId);
    }

    [Fact]
    public void Recommender_TypeMatchOutweighsDuration()
    {
        var f = new MeetingFeatures { PredictedType = "technical_review", DurationMinutes = 60 };
        var (best, _) = TemplateRecommender.Recommend(f);
        Assert.Equal("technical_review", best.TemplateId);
    }

    [Fact]
    public void Recommender_FallbackIsGeneralStandard()
    {
        Assert.Equal("general_standard", MinutesTemplateLibrary.FallbackId);
        Assert.Equal("general_standard", MinutesTemplateLibrary.ById("no_such_id").Id);
        Assert.Equal("general_standard", MinutesTemplateLibrary.ById(null).Id);
    }

    [Fact]
    public void Recommender_ReturnsTwoAlternatives()
    {
        var (_, alts) = TemplateRecommender.Recommend(new MeetingFeatures { DurationMinutes = 30 });
        Assert.Equal(2, alts.Count);
    }

    // ── StructuredMinutes parsing ──────────────────────────────────────────

    [Fact]
    public void Parse_StripsMarkdownFences()
    {
        var m = StructuredMinutes.ParseLlmResponse("```json\n{\"summary\":\"ok\"}\n```");
        Assert.Equal("ok", m.Summary);
    }

    [Fact]
    public void Parse_AcceptsSurroundingProse()
    {
        var m = StructuredMinutes.ParseLlmResponse("这是结果：\n{\"summary\":\"done\",\"risks\":[\"r1\"]}\n以上。");
        Assert.Equal("done", m.Summary);
        Assert.Equal(new[] { "r1" }, m.Risks);
    }

    [Fact]
    public void Parse_AliasKeys()
    {
        var m = StructuredMinutes.ParseLlmResponse(
            "{\"summary\":\"s\",\"openQuestions\":[\"q\"],\"actionItems\":[{\"task\":\"t\",\"assignedTo\":\"o\",\"due_date\":\"d\"}]}");
        Assert.Equal(new[] { "q" }, m.OpenQuestions);
        Assert.Single(m.ActionItems);
        Assert.Equal("o", m.ActionItems[0].Owner);
        Assert.Equal("d", m.ActionItems[0].Deadline);
    }

    [Fact]
    public void Parse_NonJsonFallsBackToRawSummary()
    {
        var m = StructuredMinutes.ParseLlmResponse("plain text, no json");
        Assert.Equal("plain text, no json", m.Summary);
    }

    [Theory]
    [InlineData("高", "high")]
    [InlineData("P0", "high")]
    [InlineData("medium", "medium")]
    [InlineData("低", "low")]
    [InlineData("p3", "low")]
    [InlineData("weird", null)]
    [InlineData(null, null)]
    public void NormalizePriority_MatchesSpec(string? raw, string? expected)
        => Assert.Equal(expected, StructuredMinutes.NormalizePriority(raw));

    // ── MinutesQualityAssessor ─────────────────────────────────────────────

    private static List<Topic> TopicsWith(string[] decisions, (string Owner, string Task, string? Deadline)[] actions)
    {
        var t = new Topic { Title = "t", StartTime = DateTime.Now };
        foreach (var d in decisions) t.Decisions.Add(new Decision { DecisionText = d, Timestamp = DateTime.Now });
        foreach (var a in actions) t.ActionItems.Add(new ActionItem { AssignedTo = a.Owner, Task = a.Task, Deadline = a.Deadline, Timestamp = DateTime.Now });
        return new List<Topic> { t };
    }

    [Fact]
    public void Quality_PerfectMinutesScores100()
    {
        var topics = TopicsWith(new[] { "决定采用方案A上线" }, new[] { ("张三", "张三完成上线检查清单", (string?)"周五") });
        var minutes = new StructuredMinutes
        {
            Summary = "本次会议讨论了上线方案并确定了行动项安排。",
            Decisions = { new StructuredMinutes.DecisionItem { Text = "决定采用方案A上线" } },
            ActionItems = { new StructuredMinutes.ActionItemFull { Task = "张三完成上线检查清单", Owner = "张三", Deadline = "周五" } },
            Risks = { "回滚方案待确认" }
        };
        var template = MinutesTemplateLibrary.ById("executive_business");
        var q = MinutesQualityAssessor.Assess(minutes, topics, template);
        Assert.Equal(100, q.Score);
        Assert.Equal("High", q.Confidence);
        Assert.False(q.NeedsHumanReview);
    }

    [Fact]
    public void Quality_MissingDecisionsDeducts15()
    {
        var topics = TopicsWith(new[] { "决定采用方案A上线", "决定推迟移动端发布", "决定增加测试覆盖", "决定砍掉旧接口" },
            Array.Empty<(string, string, string?)>());
        var minutes = new StructuredMinutes { Summary = new string('总', 30) };
        var q = MinutesQualityAssessor.Assess(minutes, topics, MinutesTemplateLibrary.ById(null));
        Assert.True(q.Score <= 100 - 15);
        Assert.Contains(q.Issues, i => i.Length > 0);
    }

    [Fact]
    public void Quality_ModelSelfReferenceDeducts6()
    {
        var minutes = new StructuredMinutes { Summary = "作为AI，我认为" + new string('会', 30) };
        var q = MinutesQualityAssessor.Assess(minutes, new List<Topic>(), MinutesTemplateLibrary.ById(null));
        Assert.Equal(94, q.Score);
    }

    // ── ThemeClassifier pure helpers ───────────────────────────────────────

    [Fact]
    public void Similarity_IdenticalTextIsOne()
        => Assert.Equal(1.0, ThemeClassifier.Similarity("产品上线筹备会议", "产品上线筹备会议"));

    [Fact]
    public void Similarity_UnrelatedTextIsLow()
        => Assert.True(ThemeClassifier.Similarity("产品上线筹备会议讨论", "abcdefghijklmnop") < 0.15);

    [Fact]
    public void TopKeywords_FiltersStopWordsAndSingles()
    {
        var kw = ThemeClassifier.TopKeywords("上线 上线 上线 部署 部署 我们 我们 我们 可以 可以 可以");
        Assert.Contains("上线", kw);
        Assert.Contains("部署", kw);
        Assert.DoesNotContain("我们", kw);
        Assert.DoesNotContain("可以", kw);
    }

    // ── CrossMeetingActionTracker ──────────────────────────────────────────

    [Fact]
    public void Tracker_GroupsSimilarTasksAcrossMeetings()
    {
        var t0 = DateTime.Now;
        var items = new List<ActionItem>
        {
            new() { Task = "跟进客户合同签署流程", AssignedTo = "张三", Timestamp = t0 },
            new() { Task = "跟进客户合同签署",     AssignedTo = "张三", Timestamp = t0.AddDays(7) },
            new() { Task = "准备下个季度预算草案", AssignedTo = "李四", Timestamp = t0.AddDays(3) },
        };
        var tracked = CrossMeetingActionTracker.Group(items);
        Assert.Equal(2, tracked.Count);
        var contract = tracked.First(t => t.MentionCount == 2);
        Assert.Equal("跟进客户合同签署", contract.Representative.Task); // latest occurrence represents
    }

    // ── MeetingFeatureExtractor ────────────────────────────────────────────

    [Fact]
    public void Extractor_ShortStandupTextPredictsStandup()
    {
        var session = new MeetingSession { StartTime = DateTime.Now, EndTime = DateTime.Now.AddMinutes(10) };
        var topic = new Topic { Title = "站会", StartTime = DateTime.Now };
        foreach (var line in new[] { "昨天完成了接口联调", "今天继续测试部署", "明天处理回归", "目前有一个阻塞" })
            topic.Transcripts.Add(new Transcript { Text = line, Timestamp = DateTime.Now });
        var f = MeetingFeatureExtractor.Extract(session, new List<Topic> { topic }, new List<Screenshot>());
        Assert.Equal("daily_standup", f.PredictedType);
        Assert.Equal(10, f.DurationMinutes);
    }

    [Fact]
    public void Extractor_WhiteboardScreenshotBoostsBrainstorming()
    {
        var session = new MeetingSession { StartTime = DateTime.Now, EndTime = DateTime.Now.AddMinutes(60) };
        var topic = new Topic { Title = "讨论", StartTime = DateTime.Now };
        topic.Transcripts.Add(new Transcript { Text = "想法 创意 点子 想法 创意 点子 想法 创意 点子 头脑风暴", Timestamp = DateTime.Now });
        var shots = new List<Screenshot> { new() { FilePath = "x", ContentType = "whiteboard", Timestamp = DateTime.Now } };
        var f = MeetingFeatureExtractor.Extract(session, new List<Topic> { topic }, shots);
        Assert.True(f.WhiteboardDetected);
        Assert.Equal("brainstorming", f.PredictedType);
    }
}
