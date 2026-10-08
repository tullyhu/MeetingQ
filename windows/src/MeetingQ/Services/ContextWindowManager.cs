namespace MeetingQ.Services;

/// <summary>
/// Holds recent meeting context used to build prompts for LLM calls.
/// Lifecycle: created per session in FloatingWindowViewModel, cleared on stop.
/// In text-only mode the screenshots collection stays empty.
/// </summary>
public class ContextWindowManager
{
    private readonly Queue<string> _recentTranscripts = new(capacity: 30);
    private readonly List<ScreenshotSummary> _recentScreenshots = new(capacity: 5);
    private readonly List<string> _decisions = new(capacity: 12);
    private readonly List<ActionItemEntry> _actionItems = new(capacity: 12);
    private string _compressedHistory = string.Empty;
    private string _currentTopic = string.Empty;
    private string _meetingTitle = string.Empty;
    private readonly List<string> _participants = new();

    public const int MaxTranscripts = 25;
    public const int MaxScreenshots = 3;
    public const int MaxDecisions = 10;
    public const int MaxActionItems = 10;

    // ── Mutators ──────────────────────────────────────────────────────────

    public void AddTranscript(string text)
    {
        _recentTranscripts.Enqueue(text);
        if (_recentTranscripts.Count > MaxTranscripts)
            _recentTranscripts.Dequeue();
    }

    public void AddScreenshotSummary(string aiSummary, string timeLabel)
    {
        _recentScreenshots.Add(new ScreenshotSummary(aiSummary, timeLabel));
        if (_recentScreenshots.Count > MaxScreenshots)
            _recentScreenshots.RemoveAt(0);
    }

    public void SetCompressedHistory(string history) => _compressedHistory = history;

    public void SetCurrentTopic(string topic) => _currentTopic = topic;

    public void SetMeetingTitle(string title) => _meetingTitle = title;

    public void AddParticipant(string name)
    {
        if (!_participants.Contains(name))
            _participants.Add(name);
    }

    public void AddDecision(string decision)
    {
        if (!_decisions.Contains(decision))
        {
            _decisions.Add(decision);
            if (_decisions.Count > MaxDecisions)
                _decisions.RemoveAt(0);
        }
    }

    public void AddActionItem(string task, string assignedTo, string? deadline)
    {
        if (!_actionItems.Any(a => a.Task == task))
        {
            _actionItems.Add(new ActionItemEntry(task, assignedTo, deadline));
            if (_actionItems.Count > MaxActionItems)
                _actionItems.RemoveAt(0);
        }
    }

    /// <summary>Clears screenshot summaries — called when switching to text-only mode mid-session.</summary>
    public void ClearScreenshots() => _recentScreenshots.Clear();

    public void Clear()
    {
        _recentTranscripts.Clear();
        _recentScreenshots.Clear();
        _decisions.Clear();
        _actionItems.Clear();
        _compressedHistory = string.Empty;
        _currentTopic = string.Empty;
        _meetingTitle = string.Empty;
        _participants.Clear();
    }

    // ── Context builders ──────────────────────────────────────────────────

    /// <summary>Builds context dict for the multimodal stage summary prompt.</summary>
    public MultimodalContext BuildContext()
    {
        return new MultimodalContext
        {
            MeetingTitle = _meetingTitle,
            Participants = _participants.ToList(),
            CurrentTopic = _currentTopic,
            CompressedHistory = _compressedHistory,
            ScreenshotSummaries = _recentScreenshots.ToList(),
            Transcripts = _recentTranscripts.ToList(),
            Decisions = _decisions.ToList(),
            ActionItems = _actionItems.ToList()
        };
    }

    /// <summary>Builds context specifically for VisionService screenshot analysis.</summary>
    public VisionContext BuildContextForVision(DateTime screenshotTimestamp)
    {
        // Surrounding transcripts: a few lines before and after the screenshot time
        return new VisionContext
        {
            CurrentTopic = _currentTopic,
            MeetingTitle = _meetingTitle,
            SurroundingTranscripts = _recentTranscripts.TakeLast(8).ToList()
        };
    }
}

// ── Supporting types ─────────────────────────────────────────────────────

public record ScreenshotSummary(string AiSummary, string TimeLabel);

public record ActionItemEntry(string Task, string AssignedTo, string? Deadline);

public class MultimodalContext
{
    public string MeetingTitle { get; init; } = string.Empty;
    public List<string> Participants { get; init; } = new();
    public string CurrentTopic { get; init; } = string.Empty;
    public string CompressedHistory { get; init; } = string.Empty;
    public List<ScreenshotSummary> ScreenshotSummaries { get; init; } = new();
    public List<string> Transcripts { get; init; } = new();
    public List<string> Decisions { get; init; } = new();
    public List<ActionItemEntry> ActionItems { get; init; } = new();
}

public class VisionContext
{
    public string MeetingTitle { get; init; } = string.Empty;
    public string CurrentTopic { get; init; } = string.Empty;
    public List<string> SurroundingTranscripts { get; init; } = new();
}
