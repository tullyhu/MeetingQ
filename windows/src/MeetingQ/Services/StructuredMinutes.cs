using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace MeetingQ.Services;

/// <summary>
/// Structured minutes model + LLM response parsing — port of macOS StructuredMinutes.swift.
/// JSON shape is identical so documents stay interchangeable across platforms.
/// </summary>
public sealed class StructuredMinutes
{
    public sealed class DecisionItem
    {
        [JsonPropertyName("text")] public string Text { get; set; } = string.Empty;
        [JsonPropertyName("rationale")] public string? Rationale { get; set; }
        [JsonPropertyName("source_speaker")] public string? SourceSpeaker { get; set; }
    }

    public sealed class ActionItemFull
    {
        [JsonPropertyName("task")] public string Task { get; set; } = string.Empty;
        [JsonPropertyName("owner")] public string Owner { get; set; } = string.Empty;
        [JsonPropertyName("deadline")] public string? Deadline { get; set; }
        [JsonPropertyName("priority")] public string? Priority { get; set; }
        [JsonPropertyName("source_speaker")] public string? SourceSpeaker { get; set; }
    }

    public sealed class TopicDetail
    {
        [JsonPropertyName("title")] public string Title { get; set; } = string.Empty;
        [JsonPropertyName("points")] public List<string> Points { get; set; } = new();
    }

    [JsonPropertyName("summary")] public string Summary { get; set; } = string.Empty;
    [JsonPropertyName("decisions")] public List<DecisionItem> Decisions { get; set; } = new();
    [JsonPropertyName("action_items")] public List<ActionItemFull> ActionItems { get; set; } = new();
    [JsonPropertyName("risks")] public List<string> Risks { get; set; } = new();
    [JsonPropertyName("open_questions")] public List<string> OpenQuestions { get; set; } = new();
    [JsonPropertyName("key_highlights")] public List<string> Highlights { get; set; } = new();
    [JsonPropertyName("next_steps")] public List<string> NextSteps { get; set; } = new();
    [JsonPropertyName("topic_details")] public List<TopicDetail> TopicDetails { get; set; } = new();

    public string Encode() => JsonSerializer.Serialize(this);

    public static StructuredMinutes? Decode(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try { return JsonSerializer.Deserialize<StructuredMinutes>(json); }
        catch { return null; }
    }

    public static StructuredMinutes ParseLlmResponse(string response)
    {
        var text = response.Trim();
        if (text.StartsWith("```"))
            text = Regex.Replace(text, @"^```\w*\n?|\n?```$", "");
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        var minutes = new StructuredMinutes();
        if (start < 0 || end <= start)
        {
            minutes.Summary = response;
            return minutes;
        }
        text = text[start..(end + 1)];

        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(text);
            root = doc.RootElement.Clone();
        }
        catch
        {
            minutes.Summary = response;
            return minutes;
        }
        if (root.ValueKind != JsonValueKind.Object)
        {
            minutes.Summary = response;
            return minutes;
        }

        minutes.Summary       = GetStr(root, "summary") ?? string.Empty;
        minutes.Risks         = GetStringArray(root, "risks", "risk_items");
        minutes.OpenQuestions = GetStringArray(root, "open_questions", "openQuestions");
        minutes.Highlights    = GetStringArray(root, "key_highlights", "highlights");
        minutes.NextSteps     = GetStringArray(root, "next_steps", "nextSteps");

        foreach (var key in new[] { "decisions" })
        {
            if (!root.TryGetProperty(key, out var arr) || arr.ValueKind != JsonValueKind.Array) continue;
            foreach (var item in arr.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String)
                {
                    var s = item.GetString();
                    if (!string.IsNullOrWhiteSpace(s))
                        minutes.Decisions.Add(new DecisionItem { Text = s });
                }
                else if (item.ValueKind == JsonValueKind.Object)
                {
                    var s = GetStr(item, "text");
                    if (s is null) continue;
                    minutes.Decisions.Add(new DecisionItem
                    {
                        Text = s,
                        Rationale = GetStr(item, "rationale"),
                        SourceSpeaker = GetStr(item, "source_speaker") ?? GetStr(item, "speaker")
                    });
                }
            }
        }

        foreach (var key in new[] { "action_items", "actionItems", "actions" })
        {
            if (!root.TryGetProperty(key, out var arr) || arr.ValueKind != JsonValueKind.Array) continue;
            foreach (var item in arr.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                var task = GetStr(item, "task") ?? string.Empty;
                if (string.IsNullOrWhiteSpace(task)) continue;
                minutes.ActionItems.Add(new ActionItemFull
                {
                    Task = task,
                    Owner = GetStr(item, "owner") ?? GetStr(item, "assignedTo") ?? string.Empty,
                    Deadline = GetStr(item, "deadline") ?? GetStr(item, "due_date"),
                    Priority = NormalizePriority(GetStr(item, "priority")),
                    SourceSpeaker = GetStr(item, "source_speaker") ?? GetStr(item, "speaker")
                });
            }
            if (minutes.ActionItems.Count > 0) break;
        }

        foreach (var key in new[] { "topic_details", "agenda" })
        {
            if (!root.TryGetProperty(key, out var arr) || arr.ValueKind != JsonValueKind.Array) continue;
            foreach (var item in arr.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                var title = GetStr(item, "title");
                if (title is null) continue;
                var points = new List<string>();
                if (item.TryGetProperty("points", out var pts) && pts.ValueKind == JsonValueKind.Array)
                    foreach (var p in pts.EnumerateArray())
                        if (p.ValueKind == JsonValueKind.String && p.GetString() is { } ps)
                            points.Add(ps);
                minutes.TopicDetails.Add(new TopicDetail { Title = title, Points = points });
            }
            if (minutes.TopicDetails.Count > 0) break;
        }
        return minutes;
    }

    private static string? GetStr(JsonElement obj, string key)
        => obj.ValueKind == JsonValueKind.Object
           && obj.TryGetProperty(key, out var v)
           && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    private static List<string> GetStringArray(JsonElement root, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (!root.TryGetProperty(key, out var arr) || arr.ValueKind != JsonValueKind.Array) continue;
            var outList = arr.EnumerateArray()
                .Where(e => e.ValueKind == JsonValueKind.String)
                .Select(e => e.GetString()!)
                .Where(s => !string.IsNullOrWhiteSpace(s))
                .ToList();
            if (outList.Count > 0) return outList;
        }
        return new List<string>();
    }

    public static string? NormalizePriority(string? raw)
    {
        if (raw is null) return null;
        var lower = raw.ToLowerInvariant();
        if (lower.Contains('高') || lower is "high" or "p0" or "p1") return "high";
        if (lower.Contains('低') || lower is "low" or "p3") return "low";
        if (lower.Contains('中') || lower is "medium" or "mid" or "p2") return "medium";
        return null;
    }

    public static string PriorityIcon(string? priority) => priority switch
    {
        "high" => "🔴", "medium" => "🟡", "low" => "🟢", _ => "⚪"
    };
}
