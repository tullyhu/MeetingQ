using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MeetingQ.Data;
using MeetingQ.Infrastructure;
using MeetingQ.Services;
using MeetingQ.Services.Interfaces;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using System.Collections.ObjectModel;
using System.IO;
using System.Text;

namespace MeetingQ.ViewModels;

public class TranscriptItem
{
    public DateTime Timestamp { get; init; }
    public string   TimeLabel => Timestamp.ToString("HH:mm:ss");
    public string?  Speaker   { get; set; }
    public string   Text      { get; init; } = string.Empty;
}

public class ActionItemDisplay
{
    public string AssignedTo { get; init; } = string.Empty;
    public string Task       { get; init; } = string.Empty;
    public string? Deadline  { get; init; }
    public string Label => LocalizationManager.Instance.IsEnglish
        ? (string.IsNullOrEmpty(Deadline) ? $"{AssignedTo}: {Task}" : $"{AssignedTo}: {Task} ({Deadline})")
        : (string.IsNullOrEmpty(Deadline) ? $"{AssignedTo}：{Task}" : $"{AssignedTo}：{Task}（{Deadline}）");
}

public partial class SessionItem : ObservableObject
{
    public int      SessionId       { get; init; }
    public string   Title           { get; init; } = string.Empty;
    public DateTime StartTime       { get; init; }
    public DateTime? EndTime        { get; init; }
    public int      ScreenshotCount { get; init; }
    public string   DateLabel       => StartTime.ToString(
        LocalizationManager.Instance.IsEnglish ? "MMM dd, yyyy  HH:mm" : "yyyy年MM月dd日  HH:mm");
    public string   DurationLabel
    {
        get
        {
            if (EndTime is null) return "—";
            var d = EndTime.Value > StartTime ? EndTime.Value - StartTime : TimeSpan.Zero;
            return d.TotalHours >= 1
                ? $"{(int)d.TotalHours}h {d.Minutes}m"
                : $"{d.Minutes}m {d.Seconds}s";
        }
    }
    [ObservableProperty]
    private string? _overallSummary;
    public List<string>            TopicTitles    { get; init; } = new();
    public string TopicsLabel => TopicTitles.Count == 0 ? LocalizationManager.Get("HistNoTopics") : string.Join("  ·  ", TopicTitles);

    // ── Mutable detail properties (set after lazy load; notify UI) ──

    [ObservableProperty]
    private List<string> _topicSummaries = new();   // same order as TopicTitles; null entries for missing

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(TranscriptCountLabel))]
    private int _transcriptCount;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasTranscripts))]
    [NotifyPropertyChangedFor(nameof(TranscriptCountLabel))]
    private List<TranscriptItem> _transcripts = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasScreenshots))]
    private List<ScreenshotItem> _screenshotPaths = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasDecisions))]
    private List<string> _decisions = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasActionItems))]
    private List<ActionItemDisplay> _actionItems = new();

    // ── Structured minutes (template pipeline) ──

    public string? TemplateId { get; set; }
    public string? TemplateName => MinutesTemplateLibrary.DisplayName(TemplateId);
    public int?    QualityScore { get; set; }
    public int?    ThemeId      { get; set; }
    public string? ThemeName    { get; set; }
    public string? MinutesJson  { get; set; }

    private StructuredMinutes? _minutes;
    private bool _minutesParsed;
    public StructuredMinutes? Minutes
    {
        get
        {
            if (!_minutesParsed)
            {
                _minutes = StructuredMinutes.Decode(MinutesJson);
                _minutesParsed = true;
            }
            return _minutes;
        }
    }

    public bool HasMinutesMeta   => TemplateName is not null || QualityScore is not null || ThemeName is not null;
    public string MinutesMetaLabel
    {
        get
        {
            var parts = new List<string>();
            if (ThemeName is not null)
                parts.Add((LocalizationManager.Instance.IsEnglish ? "Theme: " : "主题：") + ThemeName);
            if (TemplateName is not null)
                parts.Add((LocalizationManager.Instance.IsEnglish ? "Template: " : "模板：") + TemplateName);
            if (QualityScore is { } q)
                parts.Add((LocalizationManager.Instance.IsEnglish ? "Quality: " : "质量评分：") + q);
            return string.Join("   ·   ", parts);
        }
    }

    public bool HasHighlights    => Minutes?.Highlights.Count > 0;
    public bool HasRisks         => Minutes?.Risks.Count > 0;
    public bool HasOpenQuestions => Minutes?.OpenQuestions.Count > 0;
    public bool HasNextSteps     => Minutes?.NextSteps.Count > 0;
    public bool HasTopicDetails  => Minutes?.TopicDetails.Count > 0;

    public List<string> Highlights    => Minutes?.Highlights    ?? new();
    public List<string> Risks         => Minutes?.Risks         ?? new();
    public List<string> OpenQuestions => Minutes?.OpenQuestions ?? new();
    public List<string> NextSteps     => Minutes?.NextSteps     ?? new();
    public List<StructuredMinutes.TopicDetail> TopicDetails => Minutes?.TopicDetails ?? new();

    /// <summary>Raises change notifications for all minutes-derived properties.</summary>
    public void NotifyMinutesChanged()
    {
        _minutesParsed = false;
        OnPropertyChanged(nameof(Minutes));
        OnPropertyChanged(nameof(TemplateName));
        OnPropertyChanged(nameof(HasMinutesMeta));
        OnPropertyChanged(nameof(MinutesMetaLabel));
        OnPropertyChanged(nameof(HasHighlights));
        OnPropertyChanged(nameof(HasRisks));
        OnPropertyChanged(nameof(HasOpenQuestions));
        OnPropertyChanged(nameof(HasNextSteps));
        OnPropertyChanged(nameof(HasTopicDetails));
        OnPropertyChanged(nameof(Highlights));
        OnPropertyChanged(nameof(Risks));
        OnPropertyChanged(nameof(OpenQuestions));
        OnPropertyChanged(nameof(NextSteps));
        OnPropertyChanged(nameof(TopicDetails));
    }

    public string TranscriptCountLabel => LocalizationManager.Format("HistTranscriptCountFmt", TranscriptCount);
    public bool   HasTranscripts       => Transcripts.Count > 0;
    public bool   HasScreenshots       => ScreenshotPaths.Count > 0;
    public bool   HasDecisions         => Decisions.Count > 0;
    public bool   HasActionItems       => ActionItems.Count > 0;
}

public partial class HistoryViewModel : ObservableObject
{
    private readonly IDbContextFactory<AppDbContext> _dbFactory;
    private readonly ILogger<HistoryViewModel> _logger;
    private readonly IVisionService? _vision;
    private readonly ILlmService _llm;

    // Sessions whose detail (transcripts, decisions, action items) is already loaded.
    private readonly HashSet<int> _loadedIds = new();
    private CancellationTokenSource? _detailLoadCts;

    private List<SessionItem> _allSessions = new();
    public ObservableCollection<SessionItem> Sessions { get; } = new();

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ExportCommand))]
    [NotifyCanExecuteChangedFor(nameof(ExportTranscriptCommand))]
    [NotifyCanExecuteChangedFor(nameof(DeleteCommand))]
    [NotifyCanExecuteChangedFor(nameof(ExportHtmlCommand))]
    [NotifyCanExecuteChangedFor(nameof(RegenerateWithVisionCommand))]
    [NotifyCanExecuteChangedFor(nameof(EditSpeakersCommand))]
    private SessionItem? _selectedSession;

    [ObservableProperty] private string _statusText    = LocalizationManager.Get("HistLoading");
    [ObservableProperty] private bool   _isLoading     = true;
    [ObservableProperty] private bool   _isLoadingDetail;
    [ObservableProperty] private bool   _hasSelected;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(FilteredCount))]
    private string _searchText = string.Empty;
    public int FilteredCount => Sessions.Count;
    public int TotalCount => _allSessions.Count;

    public event Func<string, string?>? ExportPathRequested;
    public event Func<string, string?>? ExportTranscriptPathRequested;
    public event Func<string, string?>? ExportHtmlPathRequested;
    public event Func<int, bool>? ConfirmDeleteRequested;
    public event Func<SessionItem, Task>? EditSpeakersRequested;

    public HistoryViewModel(IDbContextFactory<AppDbContext> dbFactory,
                             ILogger<HistoryViewModel> logger,
                             IVisionService? vision,
                             ILlmService llm)
    {
        _dbFactory = dbFactory;
        _logger    = logger;
        _vision    = vision;
        _llm       = llm;
    }

    // ── 跨会议主题过滤与行动项追踪 ────────────────────────────────────────

    public sealed record ThemeFilterItem(int? ThemeId, string Name);

    public sealed record TrackedActionDisplay(string Owner, string Task, string? Deadline, int MentionCount)
    {
        public string Label => LocalizationManager.Instance.IsEnglish
            ? $"{Owner}: {Task}{(MentionCount > 1 ? $"  ×{MentionCount}" : "")}"
            : $"{Owner}：{Task}{(MentionCount > 1 ? $"  ×{MentionCount}" : "")}";
    }

    public ObservableCollection<ThemeFilterItem> ThemeFilters { get; } = new();
    public ObservableCollection<TrackedActionDisplay> ThemeTrackedActions { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ThemeFilterActive))]
    private ThemeFilterItem? _selectedThemeFilter;

    public bool ThemeFilterActive => SelectedThemeFilter?.ThemeId is not null;
    public bool HasThemeTrackedActions => ThemeTrackedActions.Count > 0;

    partial void OnSelectedThemeFilterChanged(ThemeFilterItem? value)
    {
        ApplyFilter();
        _ = LoadThemeTrackedActionsAsync(value?.ThemeId);
    }

    private async Task LoadThemesAsync()
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();
            var themes = await db.MeetingThemes
                .Where(t => !t.IsArchived)
                .OrderByDescending(t => t.CreatedAt)
                .AsNoTracking()
                .ToListAsync();
            var keep = SelectedThemeFilter;
            ThemeFilters.Clear();
            ThemeFilters.Add(new ThemeFilterItem(null, LocalizationManager.Get("HistThemeAll")));
            foreach (var t in themes)
                ThemeFilters.Add(new ThemeFilterItem(t.ThemeId, t.Name));
            SelectedThemeFilter = keep is not null
                ? ThemeFilters.FirstOrDefault(f => f.ThemeId == keep.ThemeId) ?? ThemeFilters[0]
                : ThemeFilters[0];
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Theme] Failed to load theme list");
        }
    }

    private async Task LoadThemeTrackedActionsAsync(int? themeId)
    {
        ThemeTrackedActions.Clear();
        OnPropertyChanged(nameof(HasThemeTrackedActions));
        if (themeId is null) return;
        try
        {
            using var db = _dbFactory.CreateDbContext();
            var items = await db.ActionItems
                .Where(a => a.Topic.Session.ThemeId == themeId.Value)
                .OrderBy(a => a.Timestamp)
                .AsNoTracking()
                .ToListAsync();
            foreach (var t in CrossMeetingActionTracker.Group(items))
                ThemeTrackedActions.Add(new TrackedActionDisplay(
                    t.Representative.AssignedTo, t.Representative.Task,
                    t.Representative.Deadline, t.MentionCount));
            OnPropertyChanged(nameof(HasThemeTrackedActions));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Theme] Failed to load tracked actions for theme {ThemeId}", themeId);
        }
    }

    // ── Initial load: session list with metadata only ──────────────────────
    // No transcript/decision includes — avoids Cartesian product explosion
    // and keeps the window open instantly regardless of history size.

    public async Task LoadAsync()
    {
        IsLoading  = true;
        StatusText = LocalizationManager.Get("HistLoading");
        Sessions.Clear();
        _allSessions.Clear();
        _loadedIds.Clear();

        try
        {
            using var db = _dbFactory.CreateDbContext();

            // List view: metadata only — screenshot AISummary (long text) is
            // loaded lazily in LoadDetailAsync when a session is selected.
            var sessions = await db.Sessions
                .OrderByDescending(s => s.StartTime)
                .AsNoTracking()
                .Select(s => new
                {
                    s.SessionId,
                    s.Title,
                    s.StartTime,
                    s.EndTime,
                    s.Summary,
                    s.TemplateId,
                    s.QualityScore,
                    s.ThemeId,
                    ThemeName = s.Theme != null ? s.Theme.Name : null,
                    TopicTitles = s.Topics.OrderBy(t => t.OrderIndex).Select(t => t.Title).ToList(),
                    Screenshots = s.Screenshots
                        .OrderBy(sc => sc.Timestamp)
                        .Select(sc => new { sc.FilePath, sc.Timestamp, sc.AnalysisStatus, sc.ActiveSpeakerName })
                        .ToList()
                })
                .ToListAsync();

            // Group-by aggregate translates to SQL GROUP BY — avoids the
            // SQLite variable limit of a large IN (...) filter.
            var transcriptCounts = await db.Transcripts
                .GroupBy(t => t.Topic.SessionId)
                .Select(g => new { SessionId = g.Key, Count = g.Count() })
                .ToDictionaryAsync(x => x.SessionId, x => x.Count);

            foreach (var s in sessions)
            {
                _allSessions.Add(new SessionItem
                {
                    SessionId       = s.SessionId,
                    Title           = s.Title ?? LocalizationManager.Format("HistMeetingTitleFmt", s.StartTime),
                    StartTime       = s.StartTime,
                    EndTime         = s.EndTime,
                    OverallSummary  = s.Summary,
                    TemplateId      = s.TemplateId,
                    QualityScore    = s.QualityScore,
                    ThemeId         = s.ThemeId,
                    ThemeName       = s.ThemeName,
                    TranscriptCount = transcriptCounts.GetValueOrDefault(s.SessionId, 0),
                    ScreenshotCount = s.Screenshots.Count,
                    TopicTitles     = s.TopicTitles,
                    ScreenshotPaths = s.Screenshots
                                        .Select(sc => new ScreenshotItem(sc.FilePath, sc.Timestamp)
                                        {
                                            AnalysisStatus = sc.AnalysisStatus,
                                            ActiveSpeakerName = sc.ActiveSpeakerName
                                        })
                                        .ToList(),
                    Transcripts     = [],
                    Decisions       = [],
                    ActionItems     = []
                });
            }

            ApplyFilter();
            await LoadThemesAsync();
            StatusText = sessions.Count == 0
                ? LocalizationManager.Get("HistEmpty")
                : LocalizationManager.Format("HistTotalFmt", sessions.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load history");
            StatusText = LocalizationManager.Format("HistLoadFailFmt", ex.Message);
        }
        finally
        {
            IsLoading = false;
        }
    }

    partial void OnSearchTextChanged(string value)
    {
        ApplyFilter();
        OnPropertyChanged(nameof(FilteredCount));
    }

    private void ApplyFilter()
    {
        var selected = SelectedSession;
        Sessions.Clear();
        IEnumerable<SessionItem> filtered = _allSessions;
        if (SelectedThemeFilter?.ThemeId is { } themeId)
            filtered = filtered.Where(s => s.ThemeId == themeId);
        if (!string.IsNullOrWhiteSpace(SearchText))
            filtered = filtered.Where(s =>
                s.Title.Contains(SearchText, StringComparison.OrdinalIgnoreCase) ||
                s.TopicTitles.Any(t => t.Contains(SearchText, StringComparison.OrdinalIgnoreCase)));
        foreach (var s in filtered)
            Sessions.Add(s);
        if (selected is not null)
        {
            var stillHere = Sessions.FirstOrDefault(s => s.SessionId == selected.SessionId);
            if (stillHere is not null)
                SelectedSession = stillHere;
        }
        StatusText = string.IsNullOrWhiteSpace(SearchText)
            ? LocalizationManager.Format("HistTotalFmt", _allSessions.Count)
            : LocalizationManager.Format("HistFilterFmt", Sessions.Count, _allSessions.Count);
        OnPropertyChanged(nameof(FilteredCount));
        OnPropertyChanged(nameof(TotalCount));
    }

    // ── Lazy detail load: triggered when user selects a session ────────────

    partial void OnSelectedSessionChanged(SessionItem? value)
    {
        HasSelected = value is not null;
        ChatTurns.Clear();
        ChatDraft = string.Empty;
        NotifyChatStateChanged();
        var cts = _detailLoadCts;
        _detailLoadCts = null;
        cts?.Cancel();
        cts?.Dispose();
        if (value is not null && !_loadedIds.Contains(value.SessionId))
        {
            _detailLoadCts = new CancellationTokenSource();
            _ = LoadDetailAsync(value.SessionId, _detailLoadCts.Token);
        }
    }

    // ── 问答 rail (W4) ────────────────────────────────────────────────────

    public sealed record ChatTurn(string Question, string Answer, bool IsError);

    public ObservableCollection<ChatTurn> ChatTurns { get; } = new();

    [ObservableProperty] private string _chatDraft = string.Empty;
    [ObservableProperty] private bool _isChatAnswering;

    public bool HasChatThread => ChatTurns.Count > 0;
    private static bool HasLlm => LlmProfileStore.GetActive() is not null;

    public bool ChatEnabled =>
        SelectedSession?.HasTranscripts == true && HasLlm && !IsChatAnswering;
    public bool ChatDisabled => !ChatEnabled && !IsChatAnswering;

    /// <summary>Why asking is unavailable (no transcript vs no LLM configured).</summary>
    public string ChatDisabledReason
    {
        get
        {
            if (SelectedSession?.HasTranscripts != true) return LocalizationManager.Get("ChatNoTranscript");
            if (!HasLlm) return LocalizationManager.Get("ChatNoLlm");
            return string.Empty;
        }
    }

    public string ChatSuggestion => LocalizationManager.Get("ChatSuggestionCommitments");
    public bool ShowChatSuggestion => !HasChatThread && ChatEnabled;

    private void NotifyChatStateChanged()
    {
        OnPropertyChanged(nameof(HasChatThread));
        OnPropertyChanged(nameof(ChatEnabled));
        OnPropertyChanged(nameof(ChatDisabled));
        OnPropertyChanged(nameof(ChatDisabledReason));
        OnPropertyChanged(nameof(ChatSuggestion));
        OnPropertyChanged(nameof(ShowChatSuggestion));
    }

    [RelayCommand]
    private Task AskSuggestionAsync() => AskAboutMeetingAsync();

    [RelayCommand]
    private async Task AskAboutMeetingAsync()
    {
        var session = SelectedSession;
        var question = ChatDraft.Trim();
        if (session is null) return;
        if (string.IsNullOrEmpty(question) && !HasChatThread)
            question = ChatSuggestion;
        if (string.IsNullOrEmpty(question) || !ChatEnabled) return;

        ChatDraft = string.Empty;
        IsChatAnswering = true;
        NotifyChatStateChanged();
        try
        {
            var answer = await Task.Run(async () =>
            {
                var prompt = BuildChatPrompt(session, question);
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(90));
                return await _llm.AnalyzeAsync(prompt, cts.Token);
            });
            ChatTurns.Add(new ChatTurn(question, answer.Trim(), IsError: false));
        }
        catch (Exception ex)
        {
            ChatTurns.Add(new ChatTurn(question, ex.Message, IsError: true));
        }
        finally
        {
            IsChatAnswering = false;
            NotifyChatStateChanged();
        }
    }

    private static string BuildChatPrompt(SessionItem session, string question)
    {
        var isEn = LocalizationManager.Instance.IsEnglish;
        var sb = new StringBuilder();
        sb.AppendLine(isEn
            ? "Answer the question strictly based on the meeting transcript below. If the transcript does not contain the answer, say so."
            : "请严格根据下面的会议转录回答问题。如果转录中没有答案，请明说。");
        sb.AppendLine();
        sb.AppendLine(isEn ? "## Transcript" : "## 转录");
        var budget = 12000;
        foreach (var t in session.Transcripts)
        {
            var line = $"[{t.TimeLabel}] {(string.IsNullOrEmpty(t.Speaker) ? "" : t.Speaker + ": ")}{t.Text}";
            if (line.Length > budget) break;
            sb.AppendLine(line);
            budget -= line.Length;
        }
        sb.AppendLine();
        sb.AppendLine(isEn ? $"## Question\n{question}" : $"## 问题\n{question}");
        return sb.ToString();
    }

    private async Task LoadDetailAsync(int sessionId, CancellationToken ct = default)
    {
        IsLoadingDetail = true;
        try
        {
            using var db = _dbFactory.CreateDbContext();

            var topics = await db.Topics
                .Where(t => t.SessionId == sessionId)
                .Include(t => t.Transcripts)
                .Include(t => t.Decisions)
                .Include(t => t.ActionItems)
                .OrderBy(t => t.OrderIndex)
                .AsSplitQuery()
                .AsNoTracking()
                .ToListAsync(ct);

            ct.ThrowIfCancellationRequested();

            var allTopicSummaries = topics
                .Select(t => t.Summary ?? string.Empty)
                .ToList();

            var allTranscripts = topics
                .SelectMany(t => t.Transcripts.OrderBy(tr => tr.Timestamp))
                .Select(t => new TranscriptItem
                {
                    Timestamp = t.Timestamp,
                    Speaker   = t.Speaker,
                    Text      = t.Text
                }).ToList();

            var allDecisions = topics
                .SelectMany(t => t.Decisions.OrderBy(d => d.Timestamp))
                .Select(d => d.DecisionText)
                .ToList();

            var allActionItems = topics
                .SelectMany(t => t.ActionItems.OrderBy(a => a.Timestamp))
                .Select(a => new ActionItemDisplay
                {
                    AssignedTo = a.AssignedTo,
                    Task       = a.Task,
                    Deadline   = a.Deadline
                })
                .ToList();

            // Reload screenshots with latest AI analysis results + session summary in one query
            var detail = await db.Sessions
                .Where(s => s.SessionId == sessionId)
                .Select(s => new
                {
                    s.Summary,
                    s.MinutesJson,
                    s.TemplateId,
                    s.QualityScore,
                    s.ThemeId,
                    ThemeName = s.Theme != null ? s.Theme.Name : null,
                    Screenshots = s.Screenshots
                        .OrderBy(sc => sc.Timestamp)
                        .Select(sc => new ScreenshotItem(sc.FilePath, sc.Timestamp)
                        {
                            AiSummary = sc.AISummary,
                            AnalysisStatus = sc.AnalysisStatus,
                            ActiveSpeakerName = sc.ActiveSpeakerName
                        })
                        .ToList()
                })
                .FirstOrDefaultAsync(ct);

            ct.ThrowIfCancellationRequested();

            var allScreenshots = detail?.Screenshots ?? new List<ScreenshotItem>();
            var sessionSummary = detail?.Summary;

            // Find the target item in the Sessions list and mutate it in-place.
            var target = Sessions.FirstOrDefault(s => s.SessionId == sessionId);
            if (target is null) return;

            target.TopicSummaries  = allTopicSummaries;
            target.Transcripts     = allTranscripts;
            target.Decisions       = allDecisions;
            target.ActionItems     = allActionItems;
            target.TranscriptCount = allTranscripts.Count;
            target.ScreenshotPaths = allScreenshots;
            target.OverallSummary  = sessionSummary;
            target.MinutesJson     = detail?.MinutesJson;
            target.TemplateId      = detail?.TemplateId;
            target.QualityScore    = detail?.QualityScore;
            target.ThemeId         = detail?.ThemeId;
            target.ThemeName       = detail?.ThemeName;
            target.NotifyMinutesChanged();

            // Mark as loaded so re-selection doesn't re-fetch (only after data is applied).
            // Since SessionItem is now ObservableObject, properties notify automatically.
            _loadedIds.Add(sessionId);
        }
        catch (OperationCanceledException)
        {
            // Selection changed before the load finished — not an error.
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load session detail for {SessionId}", sessionId);
        }
        finally
        {
            IsLoadingDetail = false;
        }
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        SelectedSession = null;
        await LoadAsync();
    }

    private bool CanExport() => SelectedSession is not null;
    private bool CanDelete() => SelectedSession is not null;

    [RelayCommand(CanExecute = nameof(CanDelete))]
    private async Task DeleteAsync()
    {
        if (SelectedSession is null) return;
        if (ConfirmDeleteRequested?.Invoke(SelectedSession.SessionId) != true) return;
        var id = SelectedSession.SessionId;
        try
        {
            using var db = _dbFactory.CreateDbContext();
            var session = await db.Sessions.FindAsync(id);
            if (session is null) return;
            db.Sessions.Remove(session);
            await db.SaveChangesAsync();

            _allSessions.RemoveAll(s => s.SessionId == id);
            _loadedIds.Remove(id);
            SelectedSession = null;
            ApplyFilter();
            StatusText = LocalizationManager.Get("HistDeleted");
            _logger.LogInformation("[History] Deleted session {Id}", id);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[History] Failed to delete session {Id}", id);
            StatusText = LocalizationManager.Format("HistDeleteFailFmt", ex.Message);
        }
    }

    private bool CanEditSpeakers() => SelectedSession is not null;

    [RelayCommand(CanExecute = nameof(CanEditSpeakers))]
    private async Task EditSpeakersAsync()
    {
        if (SelectedSession is null) return;
        await EnsureDetailLoadedAsync(SelectedSession);
        if (EditSpeakersRequested is not null)
            await EditSpeakersRequested.Invoke(SelectedSession);
    }

    public static List<string> GetDistinctSpeakers(SessionItem session)
    {
        return session.Transcripts
            .Where(t => !string.IsNullOrWhiteSpace(t.Speaker))
            .Select(t => t.Speaker!)
            .Distinct()
            .OrderBy(s => s)
            .ToList();
    }

    /// <summary>
    /// Renames a speaker across all transcripts (and questions) of a session.
    /// Renaming two speakers to the same name effectively merges them.
    /// Persists to the database and updates the in-memory view.
    /// </summary>
    public async Task<bool> RenameSpeakerAsync(SessionItem session, string oldName, string newName)
    {
        newName = newName.Trim();
        if (string.IsNullOrWhiteSpace(oldName) || string.IsNullOrWhiteSpace(newName) || oldName == newName)
            return false;

        try
        {
            using var db = _dbFactory.CreateDbContext();

            var transcripts = await db.Transcripts
                .Where(t => t.Topic.SessionId == session.SessionId && t.Speaker == oldName)
                .ToListAsync();
            foreach (var t in transcripts)
                t.Speaker = newName;

            var questions = await db.Questions
                .Where(q => q.Topic.SessionId == session.SessionId && q.Speaker == oldName)
                .ToListAsync();
            foreach (var q in questions)
                q.Speaker = newName;

            await db.SaveChangesAsync();

            // Rebuild the in-memory list from the DB so the view always
            // reflects the persisted state.
            session.Transcripts = await db.Transcripts
                .Where(t => t.Topic.SessionId == session.SessionId)
                .OrderBy(t => t.Timestamp)
                .AsNoTracking()
                .Select(t => new TranscriptItem
                {
                    Timestamp = t.Timestamp,
                    Speaker   = t.Speaker,
                    Text      = t.Text
                })
                .ToListAsync();

            var updated = transcripts.Count;

            StatusText = LocalizationManager.Format("HistSpeakerRenamedFmt", oldName, newName, updated);
            _logger.LogInformation("[History] Speaker renamed: {Old} → {New} in session {Id} ({Count} transcripts)",
                oldName, newName, session.SessionId, updated);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[History] Failed to rename speaker {Old} in session {Id}",
                oldName, session.SessionId);
            StatusText = LocalizationManager.Format("HistSpeakerRenameFailFmt", ex.Message);
            return false;
        }
    }

    private bool CanRegenerateWithVision() => SelectedSession is not null && _vision is not null;

    [RelayCommand(CanExecute = nameof(CanRegenerateWithVision))]
    private async Task RegenerateWithVisionAsync()
    {
        var session = SelectedSession;
        if (session is null) return;

        if (_vision is null)
        {
            StatusText = LocalizationManager.Get("HistVisionUnavailable");
            return;
        }

        StatusText = LocalizationManager.Get("HistRegenRunning");
        _logger.LogInformation("[RegenVision] Starting vision re-analysis for session {Id}", session.SessionId);

        try
        {
            using var db = _dbFactory.CreateDbContext();

            var screenshots = await db.Screenshots
                .Where(s => s.SessionId == session.SessionId)
                .OrderBy(s => s.Timestamp)
                .ToListAsync();

            if (screenshots.Count == 0)
            {
                StatusText = LocalizationManager.Get("HistNoScreenshots");
                return;
            }

            var analyzed = 0;
            foreach (var sc in screenshots)
            {
                if (sc.AnalysisStatus == "ready" && !string.IsNullOrWhiteSpace(sc.AISummary))
                    continue;

                if (!File.Exists(sc.FilePath))
                {
                    sc.AnalysisStatus = "failed";
                    continue;
                }

                try
                {
                    var result = await _vision!.AnalyzeScreenshotAsync(
                        sc.FilePath, string.Empty, new List<string>());

                    if (!string.IsNullOrWhiteSpace(result.AiSummary) &&
                        !result.AiSummary.StartsWith('['))
                    {
                        sc.AISummary = result.AiSummary;
                        sc.MeetingRelevance = result.MeetingRelevance;
                        sc.ContentType = result.ContentType;
                        sc.AnalysisStatus = "ready";
                        analyzed++;
                    }
                    else
                    {
                        sc.AnalysisStatus = "failed";
                    }
                }
                catch (Exception ex)
                {
                    sc.AnalysisStatus = "failed";
                    _logger.LogWarning(ex, "[RegenVision] Screenshot {Id} error", sc.ScreenshotId);
                }
            }

            await db.SaveChangesAsync();

            // Regenerate the session summary so it reflects the new screenshot analysis
            if (analyzed > 0)
            {
                StatusText = LocalizationManager.Get("HistRegenSummary");
                try
                {
                    var meetingSession = await db.Sessions.FindAsync(session.SessionId);
                    var topics = await db.Topics
                        .Where(t => t.SessionId == session.SessionId)
                        .Include(t => t.Transcripts)
                        .Include(t => t.Decisions)
                        .Include(t => t.ActionItems)
                        .OrderBy(t => t.OrderIndex)
                        .AsSplitQuery()
                        .ToListAsync();

                    if (meetingSession is not null && topics.Any(t => t.Transcripts.Count > 0))
                    {
                        var ok = await MinutesPipeline.GenerateFinalMinutesAsync(
                            db, meetingSession, topics, screenshots, _llm, _logger);
                        if (!ok)
                        {
                            var prompt = FloatingWindowViewModel.BuildFinalSummaryPrompt(
                                meetingSession, topics, screenshots);
                            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
                            var response = await _llm.AnalyzeAsync(prompt, cts.Token);
                            var json = response.Trim();
                            if (json.StartsWith("```"))
                                json = System.Text.RegularExpressions.Regex.Replace(json, @"^```\w*\n?|\n?```$", "");
                            using var doc = System.Text.Json.JsonDocument.Parse(json);
                            if (doc.RootElement.TryGetProperty("summary", out var summaryEl))
                                meetingSession.Summary = summaryEl.GetString();
                        }
                        await db.SaveChangesAsync();
                        _logger.LogInformation("[RegenVision] Session summary regenerated for {Id}", session.SessionId);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "[RegenVision] Failed to regenerate session summary");
                }
            }

            // Force reload session details to show updated analysis
            _loadedIds.Remove(session.SessionId);
            await LoadDetailAsync(session.SessionId);

            StatusText = analyzed > 0
                ? LocalizationManager.Format("HistRegenDoneFmt", analyzed)
                : LocalizationManager.Get("HistRegenNoop");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[RegenVision] Failed");
            StatusText = LocalizationManager.Format("HistRegenFailFmt", ex.Message);
        }
    }

    [RelayCommand(CanExecute = nameof(CanExport))]
    private async Task ExportAsync()
    {
        if (SelectedSession is null) return;
        await EnsureDetailLoadedAsync(SelectedSession);
        var defaultName = $"MeetingMinutes_{SelectedSession.StartTime:yyyyMMdd_HHmm}.md";
        var path = ExportPathRequested?.Invoke(defaultName);
        if (path is null) return;

        try
        {
            var exportDir  = Path.GetDirectoryName(path) ?? ".";
            var mdFileName = Path.GetFileNameWithoutExtension(path);
            var assetDir   = Path.Combine(exportDir, $"{mdFileName}_files");
            var assetRel   = $"{mdFileName}_files";

            var copiedMap = await CopyScreenshotsForExportAsync(SelectedSession, assetDir);

            var md = BuildMarkdown(SelectedSession, assetRel, copiedMap);
            await File.WriteAllTextAsync(path, md, Encoding.UTF8);
            _logger.LogInformation("[Export] Saved meeting minutes to {Path} ({AssetCount} assets)",
                path, copiedMap.Count);
            StatusText = LocalizationManager.Format("HistExportedFmt", Path.GetFileName(path));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Export] Failed to save meeting minutes");
            StatusText = LocalizationManager.Format("HistExportFailFmt", ex.Message);
        }
    }

    private async Task<Dictionary<string, string>> CopyScreenshotsForExportAsync(
        SessionItem s, string assetDir)
    {
        var map = new Dictionary<string, string>();
        if (s.ScreenshotPaths.Count == 0) return map;

        Directory.CreateDirectory(assetDir);

        var index = 0;
        foreach (var si in s.ScreenshotPaths)
        {
            index++;
            var ext      = Path.GetExtension(si.FilePath);
            var relName  = $"screenshot_{si.Timestamp:HHmmss}_{index}{ext}";
            var destPath = Path.Combine(assetDir, relName);

            try
            {
                if (File.Exists(si.FilePath))
                {
                    await FileCopyAsync(si.FilePath, destPath);
                    map[si.FilePath] = relName;
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[Export] Failed to copy screenshot {Path}", si.FilePath);
            }
        }

        return map;
    }

    private static async Task FileCopyAsync(string src, string dst)
    {
        using var sourceStream = new FileStream(src, FileMode.Open, FileAccess.Read,
            FileShare.Read, 4096, FileOptions.Asynchronous);
        using var destStream = new FileStream(dst, FileMode.Create, FileAccess.Write,
            FileShare.None, 4096, FileOptions.Asynchronous);
        await sourceStream.CopyToAsync(destStream);
    }

    [RelayCommand(CanExecute = nameof(CanExport))]
    private async Task ExportHtmlAsync()
    {
        if (SelectedSession is null) return;
        await EnsureDetailLoadedAsync(SelectedSession);
        var defaultName = $"MeetingMinutes_{SelectedSession.StartTime:yyyyMMdd_HHmm}.html";
        var path = ExportHtmlPathRequested?.Invoke(defaultName);
        if (path is null) return;

        try
        {
            var dataUris = new Dictionary<string, string?>();
            foreach (var shot in SelectedSession.ScreenshotPaths)
            {
                if (dataUris.ContainsKey(shot.FilePath)) continue;
                dataUris[shot.FilePath] = await EncodeScreenshotAsDataUriAsync(shot.FilePath);
            }

            var html = BuildHtml(SelectedSession, dataUris);
            await File.WriteAllTextAsync(path, html, Encoding.UTF8);
            _logger.LogInformation("[Export] Saved meeting minutes HTML to {Path}", path);
            StatusText = LocalizationManager.Format("HistExportedFmt", Path.GetFileName(path));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Export] Failed to save meeting minutes HTML");
            StatusText = LocalizationManager.Format("HistExportFailFmt", ex.Message);
        }
    }

    private async Task<string?> EncodeScreenshotAsDataUriAsync(string filePath)
    {
        try
        {
            if (!File.Exists(filePath)) return null;

            var bytes = await File.ReadAllBytesAsync(filePath);
            var mime = Path.GetExtension(filePath).ToLowerInvariant() switch
            {
                ".jpg" or ".jpeg" => "image/jpeg",
                ".png"            => "image/png",
                ".bmp"            => "image/bmp",
                ".gif"            => "image/gif",
                _                 => "image/jpeg"
            };
            return $"data:{mime};base64,{Convert.ToBase64String(bytes)}";
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Export] Failed to encode screenshot {Path}", filePath);
            return null;
        }
    }

    [RelayCommand(CanExecute = nameof(CanExport))]
    private async Task ExportTranscriptAsync()
    {
        if (SelectedSession is null) return;
        await EnsureDetailLoadedAsync(SelectedSession);
        var defaultName = $"Transcript_{SelectedSession.StartTime:yyyyMMdd_HHmm}.txt";
        var path = ExportTranscriptPathRequested?.Invoke(defaultName);
        if (path is null) return;

        try
        {
            var text = BuildTranscriptText(SelectedSession);
            await File.WriteAllTextAsync(path, text, Encoding.UTF8);
            _logger.LogInformation("[Export] Saved transcript to {Path}", path);
            StatusText = LocalizationManager.Format("HistExportedTranscriptFmt", System.IO.Path.GetFileName(path));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Export] Failed to save transcript");
            StatusText = LocalizationManager.Format("HistExportFailFmt", ex.Message);
        }
    }

    private async Task EnsureDetailLoadedAsync(SessionItem session)
    {
        if (_loadedIds.Contains(session.SessionId)) return;
        await LoadDetailAsync(session.SessionId);
    }

    // ── Export template strings (user-facing output files; follow UI language) ──

    /// <summary>Localized labels for exported markdown / transcript / HTML files.</summary>
    private sealed class ExportStrings
    {
        public static readonly ExportStrings Current = new(LocalizationManager.Instance.IsEnglish);

        private readonly bool _en;
        private ExportStrings(bool en) => _en = en;

        public string DateLabel        => _en ? "Date:"        : "日期：";
        public string DurationLabel    => _en ? "Duration:"    : "时长：";
        public string TranscriptsLabel => _en ? "Transcripts:" : "转录条数：";
        public string ScreenshotsLabel => _en ? "Screenshots:" : "截图数：";
        public string DocTitle         => _en ? "Meeting Minutes" : "会议纪要";
        public string SectionSummary   => _en ? "Summary"         : "会议总结";
        public string SectionTopicSummaries => _en ? "Topic Summaries" : "议题摘要";
        public string SectionTopics    => _en ? "Topics"     : "议题";
        public string SectionDecisions => _en ? "Decisions"  : "决策";
        public string SectionActions   => _en ? "Action Items" : "行动项";
        public string ActionTableHeader => _en ? "| Owner | Task | Deadline |" : "| 负责人 | 任务 | 截止时间 |";
        public string ActionTableHeaderHtml => _en ? "<th>Owner</th><th>Task</th><th>Deadline</th>" : "<th>负责人</th><th>任务</th><th>截止时间</th>";
        public string SectionTranscript => _en ? "Transcript" : "会议记录";
        public string Screenshot       => _en ? "Screenshot" : "截图";
        public string ScreenshotMissing => _en ? "Screenshot (file missing)" : "截图（文件缺失）";
        public string SpeakerNote(string name) => _en ? $" — Speaker: {name}" : $" — 发言人：{name}";
        public string GeneratedFooter(string now) => _en ? $"Generated by MeetingQ — {now}" : $"由 MeetingQ 生成 — {now}";
        public string SpeakerColon => _en ? ": " : "：";
        public string DateFormat => _en ? "MMM dd, yyyy HH:mm" : "yyyy年MM月dd日 HH:mm";
        public string HtmlLang   => _en ? "en" : "zh-CN";
    }

    private static string BuildTranscriptText(SessionItem s)
    {
        var L = ExportStrings.Current;
        var sb = new StringBuilder();
        sb.AppendLine(s.Title);
        sb.AppendLine(new string('-', s.Title.Length));
        sb.AppendLine($"{L.DateLabel}{s.StartTime.ToString(L.DateFormat)}");
        sb.AppendLine($"{L.DurationLabel}{s.DurationLabel}");
        sb.AppendLine($"{L.TranscriptsLabel}{s.TranscriptCount}");
        sb.AppendLine();
        foreach (var tr in s.Transcripts)
        {
            var speaker = string.IsNullOrEmpty(tr.Speaker) ? "" : $"{tr.Speaker}{L.SpeakerColon}";
            var text = tr.Text.Replace("\r\n", " ").Replace('\n', ' ').Replace('\r', ' ');
            sb.AppendLine($"[{tr.TimeLabel}] {speaker}{text}");
        }
        return sb.ToString();
    }

    private static string EscapeMarkdown(string text)
    {
        var escaped = text
            .Replace("\\", "\\\\")
            .Replace("`", "\\`")
            .Replace("*", "\\*")
            .Replace("[", "\\[")
            .Replace("]", "\\]")
            .Replace("|", "\\|");
        var lines = escaped.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var trimmed = lines[i].TrimStart();
            if (trimmed.StartsWith('#'))
            {
                var idx = lines[i].IndexOf('#');
                lines[i] = lines[i].Insert(idx, "\\");
            }
        }
        return string.Join('\n', lines);
    }

    private static string BuildMarkdown(SessionItem s, string assetRelDir,
        Dictionary<string, string> screenshotMap)
    {
        var L = ExportStrings.Current;
        var sb = new StringBuilder();
        sb.AppendLine($"# {L.DocTitle} — {s.Title}");
        sb.AppendLine();
        sb.AppendLine($"**{L.DateLabel}** {s.StartTime.ToString(L.DateFormat)}  ");
        sb.AppendLine($"**{L.DurationLabel}** {s.DurationLabel}  ");
        sb.AppendLine($"**{L.TranscriptsLabel}** {s.TranscriptCount}  ");
        if (s.ScreenshotPaths.Count > 0)
            sb.AppendLine($"**{L.ScreenshotsLabel}** {s.ScreenshotPaths.Count}  ");
        if (s.MinutesMetaLabel.Length > 0)
            sb.AppendLine($"{s.MinutesMetaLabel}  ");
        sb.AppendLine();

        // ── Overall meeting summary ──
        if (!string.IsNullOrWhiteSpace(s.OverallSummary))
        {
            sb.AppendLine($"## {L.SectionSummary}");
            sb.AppendLine();
            sb.AppendLine($"{EscapeMarkdown(s.OverallSummary)}  ");
            sb.AppendLine();
        }

        // ── Topic summaries ──
        var summaryTexts = s.TopicSummaries
            .Where(t => !string.IsNullOrWhiteSpace(t))
            .ToList();
        if (summaryTexts.Count > 0)
        {
            sb.AppendLine($"## {L.SectionTopicSummaries}");
            sb.AppendLine();
            foreach (var t in summaryTexts)
            {
                sb.AppendLine($"{EscapeMarkdown(t)}  ");
                sb.AppendLine();
            }
        }

        // ── Topics ──
        if (s.TopicTitles.Count > 0)
        {
            sb.AppendLine($"## {L.SectionTopics}");
            for (int i = 0; i < s.TopicTitles.Count; i++)
            {
                sb.AppendLine($"- **{s.TopicTitles[i]}**");
                if (i < s.TopicSummaries.Count && !string.IsNullOrWhiteSpace(s.TopicSummaries[i]))
                    sb.AppendLine($"  {EscapeMarkdown(s.TopicSummaries[i])}");
            }
            sb.AppendLine();
        }

        // ── Decisions ──
        if (s.HasDecisions)
        {
            sb.AppendLine($"## {L.SectionDecisions}");
            foreach (var d in s.Decisions)
                sb.AppendLine($"- {EscapeMarkdown(d)}");
            sb.AppendLine();
        }

        // ── Action Items ──
        if (s.HasActionItems)
        {
            sb.AppendLine($"## {L.SectionActions}");
            sb.AppendLine(L.ActionTableHeader);
            sb.AppendLine("|--------|------|----------|");
            foreach (var a in s.ActionItems)
                sb.AppendLine($"| {EscapeMarkdown(a.AssignedTo)} | {EscapeMarkdown(a.Task)} | {EscapeMarkdown(a.Deadline ?? "—")} |");
            sb.AppendLine();
        }

        // ── Structured-minutes extras (template pipeline) ──
        if (s.Minutes is { } mins)
        {
            if (mins.Highlights.Count > 0)
            {
                sb.AppendLine($"## {MinutesSection.Highlights.Title()}");
                foreach (var h in mins.Highlights) sb.AppendLine($"- {EscapeMarkdown(h)}");
                sb.AppendLine();
            }
            if (mins.TopicDetails.Count > 0)
            {
                sb.AppendLine($"## {MinutesSection.TopicDetails.Title()}");
                foreach (var td in mins.TopicDetails)
                {
                    sb.AppendLine($"- **{EscapeMarkdown(td.Title)}**");
                    foreach (var p in td.Points) sb.AppendLine($"  - {EscapeMarkdown(p)}");
                }
                sb.AppendLine();
            }
            if (mins.Risks.Count > 0)
            {
                sb.AppendLine($"## {MinutesSection.Risks.Title()}");
                foreach (var r in mins.Risks) sb.AppendLine($"- {EscapeMarkdown(r)}");
                sb.AppendLine();
            }
            if (mins.OpenQuestions.Count > 0)
            {
                sb.AppendLine($"## {MinutesSection.OpenQuestions.Title()}");
                foreach (var q in mins.OpenQuestions) sb.AppendLine($"- {EscapeMarkdown(q)}");
                sb.AppendLine();
            }
            if (mins.NextSteps.Count > 0)
            {
                sb.AppendLine($"## {MinutesSection.NextSteps.Title()}");
                foreach (var n in mins.NextSteps) sb.AppendLine($"- {EscapeMarkdown(n)}");
                sb.AppendLine();
            }
        }

        // ── Full meeting record: transcripts + screenshots chronologically ──
        if (s.HasTranscripts || s.HasScreenshots)
        {
            sb.AppendLine($"## {L.SectionTranscript}");
            sb.AppendLine();

            var ti = 0;
            var si = 0;

            while (ti < s.Transcripts.Count || si < s.ScreenshotPaths.Count)
            {
                var haveTranscript = ti < s.Transcripts.Count;
                var haveScreenshot = si < s.ScreenshotPaths.Count;

                if (!haveScreenshot || (haveTranscript &&
                    s.Transcripts[ti].Timestamp <= s.ScreenshotPaths[si].Timestamp))
                {
                    var tr = s.Transcripts[ti++];
                    var speaker = string.IsNullOrEmpty(tr.Speaker) ? "" : $"**{tr.Speaker}**{L.SpeakerColon}";
                    var text = tr.Text.Replace("\r\n", "  \n").Replace('\n', ' ').Replace('\r', ' ');
                    sb.AppendLine($"**{tr.TimeLabel}** {speaker}{text}  ");
                    sb.AppendLine();
                }
                else
                {
                    var shot = s.ScreenshotPaths[si++];
                    if (screenshotMap.TryGetValue(shot.FilePath, out var relPath))
                    {
                        sb.AppendLine($"![{shot.TimeLabel} {L.Screenshot}]({assetRelDir}/{relPath})  ");
                        var speakerNote = !string.IsNullOrWhiteSpace(shot.ActiveSpeakerName)
                            ? L.SpeakerNote(shot.ActiveSpeakerName) : "";
                        sb.AppendLine($"*{shot.TimeLabel} {L.Screenshot}{speakerNote}*  ");
                        if (!string.IsNullOrWhiteSpace(shot.AiSummary))
                            sb.AppendLine($"> {EscapeMarkdown(shot.AiSummary)}  ");
                    }
                    else
                    {
                        var speakerNote2 = !string.IsNullOrWhiteSpace(shot.ActiveSpeakerName)
                            ? L.SpeakerNote(shot.ActiveSpeakerName) : "";
                        sb.AppendLine($"> 📷 *{shot.TimeLabel} {L.ScreenshotMissing}{speakerNote2}*  ");
                        if (!string.IsNullOrWhiteSpace(shot.AiSummary))
                            sb.AppendLine($"> {EscapeMarkdown(shot.AiSummary)}  ");
                    }
                    sb.AppendLine();
                }
            }
        }

        sb.AppendLine("---");
        sb.AppendLine($"*{L.GeneratedFooter(DateTime.Now.ToString("yyyy-MM-dd HH:mm"))}*");
        return sb.ToString();
    }

    private static string BuildHtml(SessionItem s, IReadOnlyDictionary<string, string?> dataUris)
    {
        var L = ExportStrings.Current;
        var sb = new StringBuilder();
        sb.AppendLine("<!DOCTYPE html>");
        sb.AppendLine($"<html lang=\"{L.HtmlLang}\">");
        sb.AppendLine("<head>");
        sb.AppendLine("<meta charset=\"UTF-8\">");
        sb.AppendLine("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">");
        sb.AppendLine($"<title>{L.DocTitle} — {EscapeHtml(s.Title)}</title>");
        sb.AppendLine("<style>");
        sb.AppendLine("  body { font-family: -apple-system, 'Microsoft YaHei', sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; color: #1a1a1a; line-height: 1.7; }");
        sb.AppendLine("  h1 { border-bottom: 2px solid #2563eb; padding-bottom: 12px; }");
        sb.AppendLine("  h2 { color: #2563eb; margin-top: 32px; }");
        sb.AppendLine("  .meta { color: #6b7280; font-size: 14px; }");
        sb.AppendLine("  .meta span { margin-right: 24px; }");
        sb.AppendLine("  .transcript-entry { margin: 8px 0; padding: 6px 0; }");
        sb.AppendLine("  .ts { color: #6b7280; font-size: 13px; font-weight: 600; }");
        sb.AppendLine("  .speaker { color: #2563eb; font-weight: 600; }");
        sb.AppendLine("  .screenshot-block { margin: 16px 0; }");
        sb.AppendLine("  .screenshot-block img { max-width: 100%; border: 1px solid #e5e7eb; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,.08); }");
        sb.AppendLine("  .screenshot-label { color: #9ca3af; font-size: 12px; margin-top: 4px; }");
        sb.AppendLine("  table { border-collapse: collapse; width: 100%; }");
        sb.AppendLine("  th, td { border: 1px solid #e5e7eb; padding: 8px 12px; text-align: left; }");
        sb.AppendLine("  th { background: #f3f4f6; font-weight: 600; }");
        sb.AppendLine("  ul { padding-left: 20px; }");
        sb.AppendLine("  li { margin: 4px 0; }");
        sb.AppendLine("  footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid #e5e7eb; color: #9ca3af; font-size: 13px; }");
        sb.AppendLine("</style>");
        sb.AppendLine("</head>");
        sb.AppendLine("<body>");

        sb.AppendLine($"<h1>{L.DocTitle} — {EscapeHtml(s.Title)}</h1>");
        sb.AppendLine("<p class=\"meta\">");
        sb.AppendLine($"<span>{L.DateLabel}{s.StartTime.ToString(L.DateFormat)}</span>");
        sb.AppendLine($"<span>{L.DurationLabel}{s.DurationLabel}</span>");
        sb.AppendLine($"<span>{L.TranscriptsLabel}{s.TranscriptCount}</span>");
        if (s.ScreenshotPaths.Count > 0)
            sb.AppendLine($"<span>{L.ScreenshotsLabel}{s.ScreenshotPaths.Count}</span>");
        if (s.MinutesMetaLabel.Length > 0)
            sb.AppendLine($"<span>{EscapeHtml(s.MinutesMetaLabel)}</span>");
        sb.AppendLine("</p>");

        // ── Overall meeting summary ──
        if (!string.IsNullOrWhiteSpace(s.OverallSummary))
        {
            sb.AppendLine($"<h2>{L.SectionSummary}</h2>");
            sb.AppendLine($"<p>{EscapeHtml(s.OverallSummary)}</p>");
        }

        // ── Topic summaries ──
        var summaryTextsHtml = s.TopicSummaries
            .Where(t => !string.IsNullOrWhiteSpace(t))
            .ToList();
        if (summaryTextsHtml.Count > 0)
        {
            sb.AppendLine($"<h2>{L.SectionTopicSummaries}</h2>");
            foreach (var t in summaryTextsHtml)
                sb.AppendLine($"<p>{EscapeHtml(t)}</p>");
        }

        // Topics
        if (s.TopicTitles.Count > 0)
        {
            sb.AppendLine($"<h2>{L.SectionTopics}</h2><ul>");
            for (int i = 0; i < s.TopicTitles.Count; i++)
            {
                var summary = i < s.TopicSummaries.Count && !string.IsNullOrWhiteSpace(s.TopicSummaries[i])
                    ? $" — {EscapeHtml(s.TopicSummaries[i])}"
                    : "";
                sb.AppendLine($"<li><strong>{EscapeHtml(s.TopicTitles[i])}</strong>{summary}</li>");
            }
            sb.AppendLine("</ul>");
        }

        // Decisions
        if (s.HasDecisions)
        {
            sb.AppendLine($"<h2>{L.SectionDecisions}</h2><ul>");
            foreach (var d in s.Decisions)
                sb.AppendLine($"<li>{EscapeHtml(d)}</li>");
            sb.AppendLine("</ul>");
        }

        // Action Items
        if (s.HasActionItems)
        {
            sb.AppendLine($"<h2>{L.SectionActions}</h2>");
            sb.AppendLine($"<table><thead><tr>{L.ActionTableHeaderHtml}</tr></thead><tbody>");
            foreach (var a in s.ActionItems)
                sb.AppendLine($"<tr><td>{EscapeHtml(a.AssignedTo)}</td><td>{EscapeHtml(a.Task)}</td><td>{EscapeHtml(a.Deadline ?? "—")}</td></tr>");
            sb.AppendLine("</tbody></table>");
        }

        // Structured-minutes extras (template pipeline)
        if (s.Minutes is { } minsHtml)
        {
            if (minsHtml.Highlights.Count > 0)
            {
                sb.AppendLine($"<h2>{MinutesSection.Highlights.Title()}</h2><ul>");
                foreach (var h in minsHtml.Highlights) sb.AppendLine($"<li>{EscapeHtml(h)}</li>");
                sb.AppendLine("</ul>");
            }
            if (minsHtml.TopicDetails.Count > 0)
            {
                sb.AppendLine($"<h2>{MinutesSection.TopicDetails.Title()}</h2><ul>");
                foreach (var td in minsHtml.TopicDetails)
                {
                    sb.AppendLine($"<li><strong>{EscapeHtml(td.Title)}</strong><ul>");
                    foreach (var p in td.Points) sb.AppendLine($"<li>{EscapeHtml(p)}</li>");
                    sb.AppendLine("</ul></li>");
                }
                sb.AppendLine("</ul>");
            }
            if (minsHtml.Risks.Count > 0)
            {
                sb.AppendLine($"<h2>{MinutesSection.Risks.Title()}</h2><ul>");
                foreach (var r in minsHtml.Risks) sb.AppendLine($"<li>{EscapeHtml(r)}</li>");
                sb.AppendLine("</ul>");
            }
            if (minsHtml.OpenQuestions.Count > 0)
            {
                sb.AppendLine($"<h2>{MinutesSection.OpenQuestions.Title()}</h2><ul>");
                foreach (var q in minsHtml.OpenQuestions) sb.AppendLine($"<li>{EscapeHtml(q)}</li>");
                sb.AppendLine("</ul>");
            }
            if (minsHtml.NextSteps.Count > 0)
            {
                sb.AppendLine($"<h2>{MinutesSection.NextSteps.Title()}</h2><ul>");
                foreach (var n in minsHtml.NextSteps) sb.AppendLine($"<li>{EscapeHtml(n)}</li>");
                sb.AppendLine("</ul>");
            }
        }

        // Full meeting record: transcripts + screenshots (at bottom)
        if (s.HasTranscripts || s.HasScreenshots)
        {
            sb.AppendLine($"<h2>{L.SectionTranscript}</h2>");

            var ti = 0;
            var si = 0;
            while (ti < s.Transcripts.Count || si < s.ScreenshotPaths.Count)
            {
                var haveTranscript = ti < s.Transcripts.Count;
                var haveScreenshot = si < s.ScreenshotPaths.Count;

                if (!haveScreenshot || (haveTranscript &&
                    s.Transcripts[ti].Timestamp <= s.ScreenshotPaths[si].Timestamp))
                {
                    var tr = s.Transcripts[ti++];
                    var speaker = string.IsNullOrEmpty(tr.Speaker)
                        ? "" : $"<span class=\"speaker\">{EscapeHtml(tr.Speaker)}{L.SpeakerColon}</span>";
                    sb.AppendLine($"<div class=\"transcript-entry\"><span class=\"ts\">{tr.TimeLabel}</span> {speaker}{EscapeHtml(tr.Text)}</div>");
                }
                else
                {
                    var shot = s.ScreenshotPaths[si++];
                    dataUris.TryGetValue(shot.FilePath, out var dataUri);
                    if (dataUri is not null)
                    {
                        sb.AppendLine("<div class=\"screenshot-block\">");
                        sb.AppendLine($"<img src=\"{dataUri}\" alt=\"{shot.TimeLabel} {L.Screenshot}\" loading=\"lazy\">");
                        var htmlSpeakerNote = !string.IsNullOrWhiteSpace(shot.ActiveSpeakerName)
                            ? L.SpeakerNote(EscapeHtml(shot.ActiveSpeakerName)) : "";
                        sb.AppendLine($"<div class=\"screenshot-label\">{shot.TimeLabel} {L.Screenshot}{htmlSpeakerNote}</div>");
                        if (!string.IsNullOrWhiteSpace(shot.AiSummary))
                            sb.AppendLine($"<p style=\"color:#6b7280;font-size:13px;margin-top:4px\">{EscapeHtml(shot.AiSummary)}</p>");
                        sb.AppendLine("</div>");
                    }
                    else
                    {
                        var htmlSpeakerNote2 = !string.IsNullOrWhiteSpace(shot.ActiveSpeakerName)
                            ? L.SpeakerNote(EscapeHtml(shot.ActiveSpeakerName)) : "";
                        sb.AppendLine($"<div class=\"screenshot-block\"><p>📷 {shot.TimeLabel} {L.ScreenshotMissing}{htmlSpeakerNote2}</p>");
                        if (!string.IsNullOrWhiteSpace(shot.AiSummary))
                            sb.AppendLine($"<p style=\"color:#6b7280;font-size:13px\">{EscapeHtml(shot.AiSummary)}</p>");
                        sb.AppendLine("</div>");
                    }
                }
            }
        }

        sb.AppendLine($"<footer>{L.GeneratedFooter(DateTime.Now.ToString("yyyy-MM-dd HH:mm"))}</footer>");
        sb.AppendLine("</body></html>");
        return sb.ToString();
    }

    private static string EscapeHtml(string text)
    {
        return text
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;");
    }
}
