using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MeetingQ.Data;
using MeetingQ.Infrastructure;
using MeetingQ.Models;
using MeetingQ.Services;
using MeetingQ.Services.Interfaces;
using MeetingQ.Views;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Text.Json;
using System.Windows;

namespace MeetingQ.ViewModels;

public partial class FloatingWindowViewModel : ObservableObject
{
    private readonly IAudioCaptureService   _audioCapture;
    private readonly IAsrService            _asr;
    private readonly INameDetectionService  _nameDetection;
    private readonly ILlmService            _llm;
    private readonly IScreenCaptureService  _screenCapture;
    private readonly IVisionService?        _vision;
    private readonly LocalOcrService?       _localOcr;
    private readonly IDbContextFactory<AppDbContext> _dbFactory;
    private readonly QuickSummaryPopup      _quickSummaryPopup;
    private readonly MeetingWatcherService  _meetingWatcher;
    private readonly ScreenshotAlbumWindow  _screenshotAlbumWindow;
    private readonly ScreenshotAlbumViewModel _screenshotAlbum;
    private readonly ILogger<FloatingWindowViewModel> _logger;

    // ── Observable state ────────────────────────────────────────────────

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RunSelfTestCommand))]
    [NotifyCanExecuteChangedFor(nameof(ManualTriggerAlertCommand))]
    private bool _isMonitoring;
    [ObservableProperty] private string _currentTopic     = LocalizationManager.Get("FloatTopicNotStarted");
    [ObservableProperty] private string _latestTranscript = string.Empty;
    [ObservableProperty] private string _elapsedTime      = "00:00:00";
    [ObservableProperty] private string _statusText       = LocalizationManager.Get("StatusReady");

    // ── Self-test ─────────────────────────────────────────────────────────

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RunSelfTestCommand))]
    private bool _isSelfTestRunning;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ManualTriggerAlertCommand))]
    private bool _isManualAlertRunning;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelfTestResult))]
    private string _selfTestResult = string.Empty;

    [ObservableProperty] private bool _selfTestPassed;

    /// <summary>True once a session has been started; stays true after stopping so post-session buttons remain visible.</summary>
    [ObservableProperty] private bool _hasSessionData;

    public bool HasSelfTestResult => !string.IsNullOrEmpty(SelfTestResult);

    // ── Multimodal switch ──────────────────────────────────────────────────

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(MultimodalButtonText))]
    private bool _isMultimodalEnabled;

    public string MultimodalButtonText => LocalizationManager.Get(IsMultimodalEnabled ? "FloatMultimodalOn" : "FloatMultimodalOff");

    // ── Diagnostics panel ────────────────────────────────────────────────

    [ObservableProperty] private bool   _isDiagnosticVisible;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasDiagnosticHint))]
    private string _diagnosticHint = string.Empty;

    public bool HasDiagnosticHint => !string.IsNullOrEmpty(DiagnosticHint);

    public ObservableCollection<DiagnosticItem> DiagnosticSteps { get; } = new();

    // Diagnostic step references for easy update
    private DiagnosticItem? _stepDevice;
    private DiagnosticItem? _stepAsr;
    private DiagnosticItem? _stepAudio;
    private DiagnosticItem? _stepTranscript;

    // Diagnostic timers
    private System.Timers.Timer? _audioCheckTimer;    // fires 10s after capture starts
    private System.Timers.Timer? _transcriptCheckTimer; // fires 30s after ASR connects
    private bool _audioSignalReceived;
    private bool _transcriptReceived;

    // ASR watchdog — two conditions handled:
    //   1. Continuous-speech flush: active speech for >10 s with no result (server waiting for pause)
    //   2. Silent-freeze detection: no transcript for >45 s regardless of speech state
    private System.Timers.Timer? _asrWatchdogTimer;
    private DateTime _lastTranscriptAt = DateTime.MinValue;
    // _lastSpeechBoundaryAt is reset on every transcript OR detected silence interval.
    // When it lags > 10 s behind UtcNow AND audio is active → server is stuck mid-sentence.
    private DateTime _lastSpeechBoundaryAt = DateTime.MinValue;
    private float    _lastAudioRms;

    // Self-test
    private TaskCompletionSource<string>? _selfTestTranscriptTcs;
    private DiagnosticItem? _stepPlay;
    private DiagnosticItem? _stepScreenshot;
    private DiagnosticItem? _stepLlm;
    private DiagnosticItem? _stepNameAlert;
    private DiagnosticItem? _stepVisionModel;
    private DiagnosticItem? _stepVisionAnalysis;

    // ── Internal state ────────────────────────────────────────────────────

    private System.Windows.Threading.DispatcherTimer? _elapsedTimer;
    private DateTime _startTime;
    private EventHandler<float>? _audioLevelHandler;
    private EventHandler<ScreenshotCapturedEventArgs>? _screenshotHandler;

    private readonly List<string>             _transcriptHistory = new();
    private readonly List<(DateTime Time, string Text)> _timestampedHistory = new();
    private readonly object _historyLock = new();
    private string _lastAsrText = string.Empty;   // tracks current rolling ASR segment
    private int    _lastAsrUtteranceId = -1;      // server utterance_id of current segment (-1=unknown)
    private DateTime _lastNameAlertFiredAt = DateTime.MinValue;

    private int? _currentSessionId;
    private int? _currentTopicId;

    private int  _transcriptsSinceTopicCheck;
    private bool _topicDetecting;
    [ObservableProperty] private bool _isStarting; // guards against double-start race
    private int  _asrReconnecting; // debounce ASR reconnect (Interlocked)

    private readonly SemaphoreSlim _startStopLock = new(1, 1);

    private string? _lastSpeakerLabel;
    private readonly ConcurrentDictionary<string, string> _speakerNameMap = new(); // "发言人1" → "张三"
    private readonly HashSet<string> _pendingSpeakerLabels = new();    // labels awaiting Vision result
    private readonly Dictionary<string, Dictionary<string, int>> _labelNameVotes = new(); // label → (name → votes)
    private readonly List<(DateTime Time, string Label)> _speakerTimeline = new(); // every labeled commit, for screenshot-time alignment
    private DateTime _lastSpeakerScreenshotAt = DateTime.MinValue;
    private readonly HashSet<string> _participantNames = new(StringComparer.Ordinal); // distinct names seen via Vision/OCR
    private int? _participantCountHint;                                            // "N 人参会" OCR signal
    private readonly object _participantLock = new(); // guards _participantNames / _participantCountHint / _pendingSpeakerLabels / votes
    private readonly ConcurrentDictionary<Task, byte> _pendingVisionTasks = new();
    private readonly SemaphoreSlim  _topicLock          = new(1, 1);
    private readonly List<string> _currentDecisions   = new();
    private readonly object       _decisionsLock      = new();
    private readonly List<(string AssignedTo, string Task, string? Deadline)> _currentActionItems = new();
    private readonly object       _actionItemsLock    = new();
    private int  _transcriptsSinceConclusionCheck;
    private bool _conclusionDetecting;

    // ── Multimodal / Vision ────────────────────────────────────────────────
    private ContextWindowManager? _contextManager;

    // ── Events ────────────────────────────────────────────────────────────

    // (originalText, questions, detectedAt, contextLines, screenshotPath)
    public event Action<string, string[], DateTime, string[], string?>? NameDetected;
    public event Action? ConfigurationRequired;
    public event Action? TopicChanged;
    /// <summary>Fired when start is requested but no capture window is selected. View should open the window picker.</summary>
    public event Action? WindowSelectionRequired;

    partial void OnCurrentTopicChanged(string value) => TopicChanged?.Invoke();

    // ── Constructor ───────────────────────────────────────────────────────

    public FloatingWindowViewModel(
        IAudioCaptureService    audioCapture,
        IAsrService             asr,
        INameDetectionService   nameDetection,
        ILlmService             llm,
        IScreenCaptureService   screenCapture,
        IVisionService?         vision,
        LocalOcrService?        localOcr,
        IDbContextFactory<AppDbContext> dbFactory,
        QuickSummaryPopup       quickSummaryPopup,
        ScreenshotAlbumWindow   screenshotAlbumWindow,
        ScreenshotAlbumViewModel screenshotAlbum,
        MeetingWatcherService   meetingWatcher,
        ILogger<FloatingWindowViewModel> logger)
    {
        _audioCapture          = audioCapture;
        _asr                   = asr;
        _nameDetection         = nameDetection;
        _llm                   = llm;
        _screenCapture         = screenCapture;
        _vision                = vision;
        _localOcr              = localOcr;
        _dbFactory             = dbFactory;
        _quickSummaryPopup     = quickSummaryPopup;
        _quickSummaryPopup.RefreshRequested += async () =>
        {
            try { await ShowQuickSummaryCommand.ExecuteAsync(null); }
            catch (Exception ex) { AppLog.Error("FloatingWindowViewModel", "RefreshRequested handler failed", ex); }
        };
        _screenshotAlbumWindow = screenshotAlbumWindow;
        _screenshotAlbum       = screenshotAlbum;
        _meetingWatcher        = meetingWatcher;
        _logger                = logger;

        _asr.TranscriptReceived += OnTranscriptReceived;
        _asr.ErrorReceived      += OnAsrError;

        CaptureWindowTitle = SecureStorage.Load(SecureStorageKeys.CaptureWindowTitle) ?? string.Empty;
        IsMultimodalEnabled = bool.TryParse(SecureStorage.Load(SecureStorageKeys.MultimodalEnabled), out var m) && m;
        InitDiagnosticSteps();
    }

    // ── Public helpers ────────────────────────────────────────────────────

    public IReadOnlyList<string> GetRecentTranscripts(int maxEntries = 100)
    {
        lock (_historyLock)
            return _transcriptHistory.TakeLast(maxEntries).ToList();
    }

    // ── Commands ──────────────────────────────────────────────────────────

    /// <summary>Toggles between text-only and multimodal workflow mode.</summary>
    [RelayCommand]
    private void ToggleMultimodalMode()
    {
        IsMultimodalEnabled = !IsMultimodalEnabled;
        SecureStorage.Save(SecureStorageKeys.MultimodalEnabled, IsMultimodalEnabled.ToString());

        if (!IsMultimodalEnabled)
            _contextManager?.ClearScreenshots();
        _logger.LogInformation("[Multimodal] Switched to {Mode}", IsMultimodalEnabled ? "multimodal" : "text-only");
    }

    [RelayCommand]
    private async Task StartListeningAsync()
    {
        if (IsMonitoring || IsStarting) return;
        await _startStopLock.WaitAsync();
        try
        {
        if (IsMonitoring) return;
        IsStarting = true;
        try
        {
        // Clear any carryover state from previous session
        lock (_decisionsLock)   _currentDecisions.Clear();
        lock (_actionItemsLock) _currentActionItems.Clear();
        _lastSpeakerLabel = null;
        _speakerNameMap.Clear();
        lock (_participantLock)
        {
            _pendingSpeakerLabels.Clear();
            _participantNames.Clear();
            _participantCountHint = null;
            _labelNameVotes.Clear();
        }
        lock (_speakerTimeline) _speakerTimeline.Clear();
        _lastSpeakerScreenshotAt = DateTime.MinValue;

        if (LlmProfileStore.GetActive() is null)
        {
            _logger.LogWarning("Cannot start — no active LLM profile");
            StatusText = LocalizationManager.Get("FloatNeedLlmConfig");
            ConfigurationRequired?.Invoke();
            return;
        }

        bool windowValid = !string.IsNullOrWhiteSpace(CaptureWindowTitle)
                        && FindWindowByTitle(CaptureWindowTitle) != IntPtr.Zero;
        if (!windowValid)
        {
            _logger.LogInformation("Capture window '{Title}' not found — prompting user", CaptureWindowTitle);
            StatusText = LocalizationManager.Get("FloatNeedWindow");
            RefreshWindows();
            _pendingStartAfterWindowSelect = true;
            WindowSelectionRequired?.Invoke();
            return;
        }

        _logger.LogInformation("Starting listening session");

        // Reset and show diagnostic panel
        ResetDiagnostics();
        IsDiagnosticVisible = true;

        // ── Step 1: Audio device ──
        _stepDevice!.SetRunning(LocalizationManager.Get("FloatDetectingAudio"));
        StatusText = LocalizationManager.Get("FloatDetectingAudio");
        try
        {
            await _audioCapture.StartAsync();
            var devName = _audioCapture.CurrentDeviceName ?? LocalizationManager.Get("FloatDefaultPlayback");
            _stepDevice.SetOk(devName);
            _logger.LogInformation("[Diag] Audio device: {Dev}", devName);
        }
        catch (Exception ex)
        {
            _stepDevice.SetError(ex.Message);
            DiagnosticHint = LocalizationManager.Get("FloatNoPlaybackDevice");
            StatusText = LocalizationManager.Get("FloatAudioDeviceError");
            _logger.LogError(ex, "[Diag] Audio device failed");
            return;
        }

        // ── Step 2: ASR connection ──
        _stepAsr!.SetRunning(LocalizationManager.Get("FloatConnectingAsrService"));
        StatusText = LocalizationManager.Get("FloatConnectingAsr");
        try
        {
            await _asr.ConnectAsync();
            _stepAsr.SetOk(LocalizationManager.Get("FloatConnected"));
            _logger.LogInformation("[Diag] ASR connected");
        }
        catch (Exception ex)
        {
            _stepAsr.SetError(ex.Message);
            DiagnosticHint = LocalizationManager.Get("FloatAsrModelLoadFailed");
            StatusText = LocalizationManager.Get("FloatAsrInitFailed");
            _logger.LogError(ex, "[Diag] ASR connect failed");
            // Stop audio capture that already started
            await _audioCapture.StopAsync();
            return;
        }

        // ── Wire up audio forwarding ──
        // Send audio directly from the capture pipeline to ASR (no event round-trip).
        _audioCapture.SetAsr(_asr);

        _audioLevelHandler = OnAudioLevelUpdated;
        _audioCapture.AudioLevelUpdated += _audioLevelHandler;

        // ── Step 3 & 4: monitor audio signal and ASR result ──
        _audioSignalReceived = false;
        _transcriptReceived  = false;
        _stepAudio!.SetRunning(LocalizationManager.Get("FloatWaitingAudio"));
        _stepTranscript!.SetRunning(LocalizationManager.Get("FloatWaitingTranscript"));

        // 10 s: if no audio signal by then → warn
        _audioCheckTimer = new System.Timers.Timer(10_000) { AutoReset = false };
        _audioCheckTimer.Elapsed += (_, _) =>
        {
            if (!_audioSignalReceived)
            {
                _stepAudio!.SetWarning(LocalizationManager.Get("FloatMuted"));
                DiagnosticHint = LocalizationManager.Get("FloatNoAudioHint");
                _logger.LogWarning("[Diag] No audio signal in 10s");
            }
        };
        _audioCheckTimer.Start();

        // 30 s: if no transcript by then → warn
        _transcriptCheckTimer = new System.Timers.Timer(30_000) { AutoReset = false };
        _transcriptCheckTimer.Elapsed += (_, _) =>
        {
            if (!_transcriptReceived)
            {
                _stepTranscript!.SetWarning(LocalizationManager.Get("FloatNoTranscript30"));
                if (string.IsNullOrEmpty(DiagnosticHint))
                    DiagnosticHint = LocalizationManager.Get("FloatNoTranscriptHint");
                _logger.LogWarning("[Diag] No transcript in 30s");
                // Keep panel visible when there are warnings
                IsDiagnosticVisible = true;
            }
        };
        _transcriptCheckTimer.Start();

        // ── ASR watchdog ──────────────────────────────────────────────────
        // Polls every 5 s, handles two distinct failure modes:
        //
        //  A) Display un-freeze (no reconnect):
        //     bigmodel_async emits rolling partials as speech accumulates. When someone
        //     speaks for a long stretch the display can appear frozen waiting for a commit.
        //     After 10 s of audio (RMS > 0.003) without any server update we clear
        //     _lastAsrText so the display shows a fresh start. The WebSocket session is
        //     NOT interrupted — the server retains full acoustic context and will naturally
        //     emit the complete sentence when speech pauses. Reconnecting here (previous
        //     behaviour) caused word loss at every reconnect boundary.
        //
        //  B) True server freeze detection (reconnect):
        //     Server stops sending ANY update for 30 s regardless of audio state.
        //     Only then do we force a reconnect (handles server-side hangs not caught
        //     by the 45000000/45000081 error auto-reconnect in ReceiveLoopAsync).
        _lastTranscriptAt     = DateTime.UtcNow; // baseline — don't fire immediately on start
        _lastSpeechBoundaryAt = DateTime.UtcNow; // same baseline
        _asrWatchdogTimer = new System.Timers.Timer(5_000) { AutoReset = true };
        _asrWatchdogTimer.Elapsed += async (_, _) =>
        {
            try
            {
            if (!IsMonitoring) return;
            var timeSinceBoundary = (DateTime.UtcNow - _lastSpeechBoundaryAt).TotalSeconds;

            // Case A: audio present but no server update in 10 s.
            // Do NOT disconnect/reconnect — that breaks the server's acoustic context and causes
            // word loss at every reconnect boundary (typically 1-2 words per reconnect).
            // Instead, clear the in-progress rolling partial so the display un-freezes and
            // the watchdog timer resets. The WebSocket session continues uninterrupted; the
            // server will naturally commit the full sentence when speech pauses.
            if (timeSinceBoundary >= 10 && _lastAudioRms > 0.003f)
            {
                _lastSpeechBoundaryAt = DateTime.UtcNow;
                lock (_historyLock) { _lastAsrText = string.Empty; _lastAsrUtteranceId = -1; }
                _logger.LogDebug("[ASR] Watchdog: cleared in-progress partial (rms={Rms:F4}, no reconnect)", _lastAudioRms);
                return;
            }

            // Case B: server truly frozen — no transcript at all for 30 s regardless of audio.
            // This handles real server hangs / idle-timeout edge cases where auto-reconnect
            // in ReceiveLoopAsync has not already triggered.
            if ((DateTime.UtcNow - _lastTranscriptAt).TotalSeconds >= 30)
            {
                _logger.LogWarning("[ASR] Watchdog: no transcript for ≥30 s — forcing reconnect");
                // Reset both timestamps BEFORE the reconnect so the next watchdog tick
                // (5 s later) doesn't immediately re-trigger this same path.
                _lastTranscriptAt     = DateTime.UtcNow;
                _lastSpeechBoundaryAt = DateTime.UtcNow;
                try { await _asr.FinalizeSegmentAsync(); }
                catch (Exception ex) { _logger.LogWarning(ex, "[ASR] Watchdog reconnect failed"); }
            }
            }
            catch (Exception ex) { AppLog.Error("FloatingWindowViewModel", "[ASR] Watchdog tick failed", ex); }
        };
        _asrWatchdogTimer.Start();

        // ── Inline summary: auto-refresh every 5 minutes ─────────────────
        InlineSummaryText     = string.Empty;
        IsInlineSummaryLoading = false;
        _inlineSummaryTimer = new System.Timers.Timer(300_000) { AutoReset = true };
        _inlineSummaryTimer.Elapsed += async (_, _) =>
        {
            try
            {
                if (IsMonitoring)
                    await RefreshInlineSummaryAsync();
            }
            catch (Exception ex) { AppLog.Error("FloatingWindowViewModel", "[Summary] Inline refresh tick failed", ex); }
        };
        _inlineSummaryTimer.Start();

        // ── Start elapsed timer (DispatcherTimer — ticks on the UI thread) ──
        _startTime = DateTime.Now;
        _transcriptsSinceTopicCheck       = 0;
        _transcriptsSinceConclusionCheck  = 0;

        _elapsedTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _elapsedTimer.Tick += (_, _) => ElapsedTime = (DateTime.Now - _startTime).ToString(@"hh\:mm\:ss");
        _elapsedTimer.Start();

        // Create DB session BEFORE enabling monitoring so transcripts have a topic to land in.
        await CreateSessionAsync(_startTime);

        // ── Context manager ──
        _contextManager = new ContextWindowManager();
        var sessionTitle = LocalizationManager.Format("MeetingTitleFmt", _startTime);
        _contextManager.SetMeetingTitle(sessionTitle);

        IsMonitoring   = true;
        _meetingWatcher.NotifyMonitoringChanged(true);
        HasSessionData = true;
        StatusText     = LocalizationManager.Get("FloatListening");
        CurrentTopic   = "";

        // ── Screen capture ──
        _screenshotAlbum.Clear();
        _screenshotHandler = (_, e) =>
        {
            var albumItem = _screenshotAlbum.AddScreenshot(e.FilePath, e.Timestamp);
            if (_currentSessionId.HasValue)
            {
                var sessionId = _currentSessionId.Value;
                var topicId   = _currentTopicId;
                _ = Task.Run(() => SaveScreenshotAsync(sessionId, topicId, e));
            }
            _contextManager?.AddTranscript(e.Timestamp.ToString("HH:mm:ss") + LocalizationManager.Get("FloatScreenshotTag"));

            // Multimodal: trigger Vision analysis
            if (IsMultimodalEnabled && _vision is not null && _currentTopicId.HasValue)
            {
                var filePath = e.FilePath;
                var topic = CurrentTopic;
                var sessionId = _currentSessionId;
                var visionTask = Task.Run(async () =>
                {
                    try
                    {
                        var ctx = _contextManager?.BuildContextForVision(e.Timestamp);
                        var result = await _vision.AnalyzeScreenshotAsync(
                            filePath, topic,
                            ctx?.SurroundingTranscripts ?? new List<string>());

                        // Store analysis summary in context manager
                        _contextManager?.AddScreenshotSummary(
                            result.AiSummary, e.Timestamp.ToString("HH:mm:ss"));

                        // Update DB with analysis results
                        if (sessionId.HasValue)
                        {
                            using var db = _dbFactory.CreateDbContext();
                            var screenshot = await db.Screenshots
                                .Where(s => s.FilePath == filePath && s.SessionId == sessionId)
                                .OrderByDescending(s => s.ScreenshotId)
                                .FirstOrDefaultAsync();
                            if (screenshot is not null)
                            {
                                screenshot.AISummary = result.AiSummary;
                                screenshot.MeetingRelevance = result.MeetingRelevance;
                                screenshot.ContentType = result.ContentType;
                                screenshot.OcrText = result.OcrText;
                                screenshot.KeyEntities = System.Text.Json.JsonSerializer.Serialize(result.KeyEntities);
                                screenshot.KeyNumbers = System.Text.Json.JsonSerializer.Serialize(result.KeyNumbers);
                                screenshot.KeyDates = System.Text.Json.JsonSerializer.Serialize(result.KeyDates);
                                screenshot.SlideDecisions = System.Text.Json.JsonSerializer.Serialize(result.SlideDecisions);
                                screenshot.SlideActionItems = System.Text.Json.JsonSerializer.Serialize(result.SlideActionItems);
                                screenshot.ChartType = result.ChartType;
                                screenshot.ChartInsight = result.ChartInsight;
                                screenshot.SensitivityLevel = result.SensitivityLevel;
                                screenshot.ActiveSpeakerName = result.ActiveSpeakerName;
                                screenshot.AnalysisStatus = "ready";
                                await db.SaveChangesAsync();
                            }
                        }

                        // Update album item with AI summary
                        albumItem.AiSummary = result.AiSummary;
                        albumItem.AnalysisStatus = "ready";
                        albumItem.ActiveSpeakerName = result.ActiveSpeakerName;

                        // Real-time speaker name mapping: align by the label that was
                        // active at the moment the screenshot was taken — Vision results
                        // arrive seconds later, when the current speaker may have changed.
                        if (!string.IsNullOrWhiteSpace(result.ActiveSpeakerName))
                        {
                            lock (_participantLock) _participantNames.Add(result.ActiveSpeakerName);
                            TryUpdateParticipantCountHint(result.OcrText);

                            var shotLabel = LabelAtTime(e.Timestamp);
                            if (shotLabel is not null)
                                AddSpeakerNameVote(shotLabel, result.ActiveSpeakerName);
                        }
                        else if (_localOcr is not null)
                        {
                            // Vision couldn't find a speaker name — try local OCR fast path
                            var ocrName = await _localOcr.ExtractActiveSpeakerNameAsync(filePath);
                            if (ocrName is not null)
                            {
                                lock (_participantLock) _participantNames.Add(ocrName);
                                var shotLabel = LabelAtTime(e.Timestamp);
                                if (shotLabel is not null)
                                    AddSpeakerNameVote(shotLabel, ocrName);
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger.LogWarning(ex, "[Vision] Analysis failed for {Path}", filePath);
                    }
                });
                _pendingVisionTasks[visionTask] = 0;
                _ = visionTask.ContinueWith(t => _pendingVisionTasks.TryRemove(t, out byte _),
                    TaskContinuationOptions.ExecuteSynchronously);
            }
            // Text-only mode: local WinRT OCR still extracts readable text, the active
            // speaker name, and the participant count — so screenshots stay useful
            // without a Vision model.
            else if (!IsMultimodalEnabled && _localOcr is not null && _currentTopicId.HasValue)
            {
                var filePath  = e.FilePath;
                var sessionId = _currentSessionId;
                var shotTime  = e.Timestamp;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        var text = await _localOcr.OcrAsync(filePath);
                        if (text is null) return;

                        var count = LocalOcrService.ExtractParticipantCount(text);
                        if (count.HasValue)
                            lock (_participantLock)
                                _participantCountHint = Math.Max(_participantCountHint ?? 0, count.Value);

                        var name = LocalOcrService.ExtractSpeakerName(text);
                        if (name is not null)
                        {
                            lock (_participantLock) _participantNames.Add(name);
                            var shotLabel = LabelAtTime(shotTime);
                            if (shotLabel is not null)
                                AddSpeakerNameVote(shotLabel, name);
                        }

                        // Persist OCR text so post-meeting mapping and summaries can use it
                        if (sessionId.HasValue)
                        {
                            using var db = _dbFactory.CreateDbContext();
                            var screenshot = await db.Screenshots
                                .Where(s => s.FilePath == filePath && s.SessionId == sessionId)
                                .OrderByDescending(s => s.ScreenshotId)
                                .FirstOrDefaultAsync();
                            if (screenshot is not null)
                            {
                                screenshot.OcrText = text.Length > 2000 ? text[..2000] : text;
                                screenshot.ActiveSpeakerName = name;
                                screenshot.AnalysisStatus = "ready";
                                await db.SaveChangesAsync();
                            }
                        }
                    }
                    catch (Exception ex) { _logger.LogWarning(ex, "[OCR] Text-only analysis failed"); }
                });
            }
        };
        _screenCapture.ScreenshotCaptured += _screenshotHandler;

        // Persist current window selection and resolve HWND
        SecureStorage.Save(SecureStorageKeys.CaptureWindowTitle, CaptureWindowTitle);
        var windowTitle = CaptureWindowTitle;
        var captureHwnd = IntPtr.Zero;
        if (!string.IsNullOrWhiteSpace(windowTitle))
        {
            captureHwnd = FindWindowByTitle(windowTitle);
            if (captureHwnd == IntPtr.Zero)
                _logger.LogWarning("[Screen] Window '{Title}' not found, falling back to full screen", windowTitle);
            else
                _logger.LogInformation("[Screen] Capturing window '{Title}' HWND={Hwnd}", windowTitle, captureHwnd);
        }
        // Skip periodic captures while the meeting has been silent for >30s — nobody is
        // speaking, so shared content is very unlikely to be changing. On-demand shots
        // (speaker switch, name alert) are unaffected.
        _screenCapture.ShouldSkipPeriodicCapture = () =>
            (DateTime.UtcNow - _lastSpeechBoundaryAt).TotalSeconds > 30;
        await _screenCapture.StartAsync(captureHwnd);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Start] StartListening failed — rolling back");
            AppLog.Error("FloatingWindowViewModel", "StartListening failed", ex);
            RollbackFailedStart();
            _ = Task.Run(CleanupAfterFailedStartAsync);
        }
        finally { IsStarting = false; }
        }
        finally { _startStopLock.Release(); }
    }

    private void RollbackFailedStart()
    {
        _audioCheckTimer?.Stop();
        _audioCheckTimer?.Dispose();
        _audioCheckTimer = null;

        _transcriptCheckTimer?.Stop();
        _transcriptCheckTimer?.Dispose();
        _transcriptCheckTimer = null;

        _asrWatchdogTimer?.Stop();
        _asrWatchdogTimer?.Dispose();
        _asrWatchdogTimer = null;

        _inlineSummaryTimer?.Stop();
        _inlineSummaryTimer?.Dispose();
        _inlineSummaryTimer = null;

        _elapsedTimer?.Stop();
        _elapsedTimer = null;

        if (_screenshotHandler is not null)
        {
            _screenCapture.ScreenshotCaptured -= _screenshotHandler;
            _screenshotHandler = null;
        }
        if (_audioLevelHandler is not null)
        {
            _audioCapture.AudioLevelUpdated -= _audioLevelHandler;
            _audioLevelHandler = null;
        }
        _audioCapture.SetAsr(null);
        _screenCapture.ShouldSkipPeriodicCapture = null;

        IsMonitoring = false;
        StatusText   = LocalizationManager.Get("FloatStartFailed");
    }

    private async Task CleanupAfterFailedStartAsync()
    {
        try { await _screenCapture.StopAsync(); }
        catch (Exception ex) { _logger.LogWarning(ex, "[Start] ScreenCapture cleanup failed"); }
        try { await _audioCapture.StopAsync(); }
        catch (Exception ex) { _logger.LogWarning(ex, "[Start] Audio cleanup failed"); }
        try { await _asr.DisconnectAsync(); }
        catch (Exception ex) { _logger.LogWarning(ex, "[Start] ASR cleanup failed"); }
    }

    [RelayCommand]
    private async Task StopListeningAsync()
    {
        if (!IsMonitoring) return;
        await _startStopLock.WaitAsync();
        try
        {
        if (!IsMonitoring) return;

        _logger.LogInformation("Stopping listening session");
        StatusText = LocalizationManager.Get("FloatStopping");

        _elapsedTimer?.Stop();
        _elapsedTimer = null;

        _audioCheckTimer?.Stop();
        _audioCheckTimer?.Dispose();
        _audioCheckTimer = null;

        _transcriptCheckTimer?.Stop();
        _transcriptCheckTimer?.Dispose();
        _transcriptCheckTimer = null;

        _asrWatchdogTimer?.Stop();
        _asrWatchdogTimer?.Dispose();
        _asrWatchdogTimer = null;

        _inlineSummaryTimer?.Stop();
        _inlineSummaryTimer?.Dispose();
        _inlineSummaryTimer = null;

        if (_screenshotHandler is not null)
        {
            _screenCapture.ScreenshotCaptured -= _screenshotHandler;
            _screenshotHandler = null;
        }
        await _screenCapture.StopAsync();

        if (_audioLevelHandler is not null)
        {
            _audioCapture.AudioLevelUpdated -= _audioLevelHandler;
            _audioLevelHandler = null;
        }
        _audioCapture.SetAsr(null);
        await _audioCapture.StopAsync();
        _screenCapture.ShouldSkipPeriodicCapture = null;

        // DisconnectAsync sends end-of-stream to flush remaining audio before closing.
        await _asr.DisconnectAsync();

        // Clear in-progress partial (not committed — may be a fragment).
        // Final sentences already committed via isFinal during the session.
        lock (_historyLock)
        {
            _lastAsrText           = string.Empty;
            _lastAsrUtteranceId    = -1;
        }

        IsMonitoring = false;
        _meetingWatcher.NotifyMonitoringChanged(false);
        StatusText   = LocalizationManager.Get("FloatStopped");
        CurrentTopic = LocalizationManager.Get("FloatTopicEnded");
        LatestTranscript = string.Empty;
        InlineSummaryText = string.Empty;
        // Keep decisions/action items in memory — they are already persisted to DB
        // and may be needed for post-session summary view.
        _transcriptsSinceConclusionCheck = 0;
        _topicDetecting       = false;
        _conclusionDetecting  = false;

        var sessionId = _currentSessionId;
        var topicId   = _currentTopicId;
        // Snapshot speaker state BEFORE clearing — EndSessionAsync runs after this and
        // needs the real-time name map / participant-count hint for post-meeting mapping.
        var speakerMapSnapshot = new Dictionary<string, string>(_speakerNameMap);
        int? participantHintSnapshot;
        lock (_participantLock) participantHintSnapshot = _participantCountHint;
        _currentSessionId = null;
        _currentTopicId   = null;
        _lastSpeakerLabel = null;
        _speakerNameMap.Clear();
        lock (_participantLock)
        {
            _pendingSpeakerLabels.Clear();
            _participantNames.Clear();
            _participantCountHint = null;
            _labelNameVotes.Clear();
        }
        lock (_speakerTimeline) _speakerTimeline.Clear();
        _contextManager?.Clear();
        _contextManager = null;

        if (sessionId.HasValue)
        {
            var endTask = Task.Run(() => EndSessionAsync(sessionId.Value, topicId,
                speakerMapSnapshot, participantHintSnapshot));
            PendingEndSessionTask = endTask;
            _ = endTask.ContinueWith(t =>
            {
                if (ReferenceEquals(PendingEndSessionTask, endTask))
                    PendingEndSessionTask = null;
            }, TaskScheduler.Default);
        }
        }
        finally { _startStopLock.Release(); }
    }

    /// <summary>Tracks the post-session finalization (summary generation, speaker mapping).
    /// Awaited by the app shutdown path before process exit.</summary>
    public Task? PendingEndSessionTask { get; private set; }

    [RelayCommand]
    private void ToggleDiagnostics() => IsDiagnosticVisible = !IsDiagnosticVisible;

    // ── Inline summary ────────────────────────────────────────────────────

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasInlineSummary))]
    private string _inlineSummaryText = string.Empty;

    [ObservableProperty] private bool _isInlineSummaryLoading;

    public bool HasInlineSummary => !string.IsNullOrEmpty(InlineSummaryText);

    private System.Timers.Timer? _inlineSummaryTimer;

    // ── Self-test command ─────────────────────────────────────────────────

    private bool CanRunSelfTest() => !IsMonitoring && !IsSelfTestRunning;

    [RelayCommand(CanExecute = nameof(CanRunSelfTest))]
    private async Task RunSelfTestAsync()
    {
        IsSelfTestRunning = true;
        SelfTestResult    = string.Empty;
        SelfTestPassed    = false;
        StatusText        = LocalizationManager.Get("FloatSelfTestRunning");

        // Reset the 4 standard steps and add 6 transient steps.
        ResetDiagnostics();
        _stepPlay       = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepTestPlayback") };
        _stepScreenshot = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepScreenshot") };
        _stepLlm        = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepLlmSummary") };
        _stepNameAlert  = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepNameAlert") };
        _stepVisionModel = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepVisionModel") };
        _stepVisionAnalysis = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepVisionAnalysis") };
        DiagnosticSteps.Add(_stepPlay);
        DiagnosticSteps.Add(_stepScreenshot);
        DiagnosticSteps.Add(_stepLlm);
        DiagnosticSteps.Add(_stepNameAlert);
        DiagnosticSteps.Add(_stepVisionModel);
        DiagnosticSteps.Add(_stepVisionAnalysis);
        IsDiagnosticVisible = true;

        EventHandler<float>?              levelHandler   = null;
        bool audioStarted = false;
        bool asrConnected = false;
        bool abortAsr     = false;   // set on early failure; skips ASR-dependent steps

        try
        {
            // ── Step 1: Audio device ──────────────────────────────────────
            _stepDevice!.SetRunning(LocalizationManager.Get("FloatDetectingAudio"));
            try
            {
                await _audioCapture.StartAsync();
                audioStarted = true;
                _stepDevice.SetOk(_audioCapture.CurrentDeviceName ?? LocalizationManager.Get("FloatDefaultPlayback"));
            }
            catch (Exception ex)
            {
                _stepDevice.SetError(ex.Message);
                SelfTestResult = LocalizationManager.Format("FloatErrAudioDeviceFmt", ex.Message);
                DiagnosticHint = LocalizationManager.Get("FloatNoPlaybackDevice");
                abortAsr = true;
            }

            // ── Step 2: ASR connection ────────────────────────────────────
            if (!abortAsr)
            {
                _stepAsr!.SetRunning(LocalizationManager.Get("FloatConnectingAsrService"));
                try
                {
                    await _asr.ConnectAsync();
                    asrConnected = true;
                    _stepAsr.SetOk(LocalizationManager.Get("FloatConnected"));
                }
                catch (Exception ex)
                {
                    _stepAsr.SetError(ex.Message);
                    SelfTestResult = LocalizationManager.Format("FloatErrAsrConnectFmt", ex.Message);
                    DiagnosticHint = LocalizationManager.Get("FloatAsrCheckHint");
                    abortAsr = true;
                }
            }

            // ── Steps 3–5: audio signal, TTS, transcript ──────────────────
            if (!abortAsr)
            {
                _audioCapture.SetAsr(_asr);
                levelHandler = (_, rms) =>
                {
                    if (_stepAudio?.State == DiagState.Running && rms > 0.005f)
                        _stepAudio.SetOk(LocalizationManager.Format("FloatAudioLevelFmt", rms));
                };
                _audioCapture.AudioLevelUpdated += levelHandler;

                _stepAudio!.SetRunning(LocalizationManager.Get("FloatWaitingAudio"));
                _stepTranscript!.SetRunning(LocalizationManager.Get("FloatWaitingTranscript"));
                _selfTestTranscriptTcs = new TaskCompletionSource<string>(
                    TaskCreationOptions.RunContinuationsAsynchronously);

                await Task.Delay(800);

                _stepPlay.SetRunning(LocalizationManager.Get("FloatPlayingTestVoice"));
                try
                {
                    var (_, isZh) = await SelfTestAudio.SpeakAsync(_logger, CancellationToken.None);
                    _stepPlay.SetOk(isZh ? LocalizationManager.Get("FloatPlayed") : LocalizationManager.Get("FloatPlayedEn"));
                    if (!isZh)
                        _logger.LogWarning("[SelfTest] No Chinese TTS voice");
                }
                catch (Exception ex)
                {
                    _stepPlay.SetError(ex.Message);
                    SelfTestResult = LocalizationManager.Format("FloatErrTtsFmt", ex.Message);
                    DiagnosticHint = LocalizationManager.Get("FloatTtsHint");
                    abortAsr = true;
                }

                if (!abortAsr)
                {
                    await Task.Delay(2_500);
                    try { await _asr.FinalizeSegmentAsync(); }
                    catch (Exception ex) { _logger.LogWarning(ex, "[SelfTest] FinalizeSegmentAsync"); }

                    _stepTranscript.SetRunning(LocalizationManager.Get("FloatWaitingAsrReturn"));
                    var winner = await Task.WhenAny(_selfTestTranscriptTcs.Task, Task.Delay(8_000));

                    if (winner == _selfTestTranscriptTcs.Task)
                    {
                        var text = _selfTestTranscriptTcs.Task.Result;
                        _stepTranscript.SetOk(LocalizationManager.Get("FloatTranscriptOk"));
                        SelfTestPassed = true;
                        SelfTestResult = LocalizationManager.Format("FloatAsrSelfTestPassFmt", text);
                        DiagnosticHint = string.Empty;
                        _logger.LogInformation("[SelfTest] ASR PASS: {Text}", text);
                    }
                    else
                    {
                        bool audioOk = _stepAudio?.State == DiagState.OK;
                        if (!audioOk)
                        {
                            _stepAudio!.SetError(LocalizationManager.Get("FloatNoAudioCaptured"));
                            _stepTranscript.SetWarning(LocalizationManager.Get("FloatNotReachedAsr"));
                            SelfTestResult = LocalizationManager.Get("FloatWasapiFail");
                            DiagnosticHint = LocalizationManager.Get("FloatWasapiHint");
                        }
                        else
                        {
                            _stepTranscript.SetError(LocalizationManager.Get("FloatNoAsrResponse"));
                            SelfTestResult = LocalizationManager.Get("FloatAsrNoReturn");
                            DiagnosticHint = LocalizationManager.Get("FloatAsrNoReturnHint");
                        }
                        _logger.LogWarning("[SelfTest] ASR FAIL — audioOk={AudioOk}", audioOk);
                    }
                }
            }

            if (abortAsr)
            {
                // Mark un-started ASR steps as skipped so they don't stay Pending
                if (_stepAsr?.State        == DiagState.Pending) _stepAsr.SetWarning(LocalizationManager.Get("FloatSkipped"));
                if (_stepAudio?.State      == DiagState.Pending) _stepAudio.SetWarning(LocalizationManager.Get("FloatSkipped"));
                if (_stepTranscript?.State == DiagState.Pending) _stepTranscript.SetWarning(LocalizationManager.Get("FloatSkipped"));
                if (_stepPlay?.State       == DiagState.Pending) _stepPlay.SetWarning(LocalizationManager.Get("FloatSkipped"));
            }

            // ── Step 6: Screenshot ────────────────────────────────────────
            string? selfTestScreenshotPath = null;
            _stepScreenshot!.SetRunning(LocalizationManager.Get("FloatCapturing"));
            try
            {
                selfTestScreenshotPath = await _screenCapture.TakeScreenshotAsync();
                _stepScreenshot.SetOk(LocalizationManager.Get("FloatSaved"));
                _logger.LogInformation("[SelfTest] Screenshot: {Path}", selfTestScreenshotPath);
            }
            catch (Exception ex)
            {
                _stepScreenshot.SetError(ex.Message);
                _logger.LogWarning(ex, "[SelfTest] Screenshot failed");
            }

            // ── Step 7: LLM 摘要 ─────────────────────────────────────────
            _stepLlm!.SetRunning(LocalizationManager.Get("FloatCallingLlm"));
            try
            {
                using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                var reply      = await _llm.AnalyzeAsync(
                    LocalizationManager.Instance.IsEnglish
                        ? "Reply with exactly one sentence: \"LLM summary connection OK\""
                        : "请用一句话回复\"LLM摘要连接正常\"",
                    cts.Token);
                var preview    = reply.Length > 24 ? reply[..24] + "…" : reply;
                _stepLlm.SetOk(preview);
                _logger.LogInformation("[SelfTest] LLM reply: {Reply}", reply);
            }
            catch (OperationCanceledException)
            {
                _stepLlm.SetError(LocalizationManager.Get("FloatTimeout15"));
                _logger.LogWarning("[SelfTest] LLM timeout");
            }
            catch (Exception ex)
            {
                _stepLlm.SetError(ex.Message);
                _logger.LogWarning(ex, "[SelfTest] LLM failed");
            }

            // ── Step 8: 被叫提醒 ──────────────────────────────────────────
            _stepNameAlert!.SetRunning(LocalizationManager.Get("FloatTriggeringAlert"));
            var userName = SecureStorage.Load(SecureStorageKeys.UserName)?.Trim();
            if (string.IsNullOrEmpty(userName)) userName = LocalizationManager.Get("FloatUser");
            var isEn = LocalizationManager.Instance.IsEnglish;
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                NameDetected?.Invoke(
                    isEn ? $"[Self-test] {userName}, what do you think of this plan?"
                         : $"[自检] 请问{userName}，你觉得这个方案怎么样？",
                    new[] { isEn ? "What do you think of this plan?" : "你觉得这个方案怎么样？" },
                    DateTime.Now,
                    new[] { isEn ? "[Self-test] Testing name-call alert popup" : "[功能自检] 测试被叫到姓名提醒弹窗" },
                    selfTestScreenshotPath));
            _stepNameAlert.SetOk(LocalizationManager.Get("FloatPopupTriggered"));
            _logger.LogInformation("[SelfTest] NameAlert triggered for '{Name}'", userName);

            // ── Step 9: Vision 模型连接 (仅多模态模式) ──────────────────────
            if (_vision is not null && IsMultimodalEnabled)
            {
                _stepVisionModel!.SetRunning(LocalizationManager.Get("FloatTestingVisionConn"));
                try
                {
                    var ok = await _vision.TestConnectionAsync();
                    if (ok)
                        _stepVisionModel.SetOk(LocalizationManager.Get("FloatVisionOk"));
                    else
                    {
                        _stepVisionModel.SetWarning(LocalizationManager.Get("FloatVisionNoResponse"));
                        _logger.LogWarning("[SelfTest] Vision connection returned false");
                    }
                }
                catch (Exception ex)
                {
                    _stepVisionModel.SetError(ex.Message);
                    _logger.LogWarning(ex, "[SelfTest] Vision connection failed");
                }

                // ── Step 10: Vision 分析测试 ────────────────────────────────
                _stepVisionAnalysis!.SetRunning(LocalizationManager.Get("FloatTestingVisionAnalysis"));
                try
                {
                    if (selfTestScreenshotPath is not null && File.Exists(selfTestScreenshotPath))
                    {
                        var result = await _vision.AnalyzeScreenshotAsync(
                            selfTestScreenshotPath,
                            LocalizationManager.Instance.IsEnglish ? "[Self-test]" : "[自检]",
                            new List<string>());
                        // "[分析失败"/"[分析超时"/"[模型未返回"/"[响应解析失败" are internal
                        // codes produced by VisionService — language-neutral, do not localize.
                        if (!string.IsNullOrWhiteSpace(result.AiSummary) &&
                            !result.AiSummary.StartsWith("[分析失败") &&
                            !result.AiSummary.StartsWith("[分析超时") &&
                            !result.AiSummary.StartsWith("[模型未返回") &&
                            !result.AiSummary.StartsWith("[响应解析失败"))
                        {
                            _stepVisionAnalysis.SetOk(LocalizationManager.Get("FloatAnalysisOk"));
                            _logger.LogInformation("[SelfTest] Vision analysis: {Summary}", result.AiSummary);
                        }
                        else
                        {
                            var reason = string.IsNullOrWhiteSpace(result.AiSummary)
                                ? LocalizationManager.Get("FloatEmptyResponse") : result.AiSummary.Trim('[', ']');
                            _stepVisionAnalysis.SetWarning(LocalizationManager.Format("FloatAnalysisInvalidFmt", reason));
                            _logger.LogWarning("[SelfTest] Vision analysis failed: {Summary}", result.AiSummary);
                            DiagnosticHint = LocalizationManager.Get("FloatVisionFailHint");
                        }
                    }
                    else
                    {
                        _stepVisionAnalysis.SetWarning(LocalizationManager.Get("FloatNoTestScreenshot"));
                    }
                }
                catch (Exception ex)
                {
                    _stepVisionAnalysis.SetWarning(LocalizationManager.Format("FloatAnalysisTestErrorFmt", ex.Message));
                    _logger.LogWarning(ex, "[SelfTest] Vision analysis test failed");
                }
            }
            else if (_stepVisionModel is not null)
            {
                _stepVisionModel.SetOk(LocalizationManager.Get("FloatSkippedTextMode"));
                _stepVisionModel.Detail = LocalizationManager.Get("FloatEnableMultimodalHint");
                _stepVisionAnalysis!.SetOk(LocalizationManager.Get("FloatSkippedTextMode"));
                _stepVisionAnalysis.Detail = LocalizationManager.Get("FloatEnableMultimodalHint");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[SelfTest] Unexpected error");
            SelfTestResult = LocalizationManager.Format("FloatSelfTestErrorFmt", ex.Message);
            DiagnosticHint = LocalizationManager.Get("FloatSeeLogHint");
        }
        finally
        {
            if (levelHandler   != null) _audioCapture.AudioLevelUpdated  -= levelHandler;
            _audioCapture.SetAsr(null);
        }

        // ── Cleanup ────────────────────────────────────────────────────────
        if (audioStarted)
            try { await _audioCapture.StopAsync(); } catch (Exception ex) { _logger.LogWarning(ex, "[SelfTest] StopAudio"); }
        if (asrConnected)
            try { await _asr.DisconnectAsync(); } catch (Exception ex) { _logger.LogWarning(ex, "[SelfTest] DisconnectAsr"); }

        // Keep transient steps visible so the user can read all results.
        // They are removed at the START of the next run (inside ResetDiagnostics).

        _selfTestTranscriptTcs = null;
        IsSelfTestRunning      = false;
        StatusText             = LocalizationManager.Get("StatusReady");
    }

    // ── Diagnostic helpers ────────────────────────────────────────────────

    private void InitDiagnosticSteps()
    {
        _stepDevice     = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepAudioDevice") };
        _stepAsr        = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepAsrConn") };
        _stepAudio      = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepAudioSignal") };
        _stepTranscript = new DiagnosticItem { Name = LocalizationManager.Get("DiagStepTranscription") };

        DiagnosticSteps.Clear();
        DiagnosticSteps.Add(_stepDevice);
        DiagnosticSteps.Add(_stepAsr);
        DiagnosticSteps.Add(_stepAudio);
        DiagnosticSteps.Add(_stepTranscript);
    }

    private void ResetDiagnostics()
    {
        DiagnosticHint = string.Empty;
        _stepDevice?.SetPending();
        _stepAsr?.SetPending();
        _stepAudio?.SetPending();
        _stepTranscript?.SetPending();

        // Remove transient steps from previous run
        foreach (var s in new[] { _stepPlay, _stepScreenshot, _stepLlm, _stepNameAlert, _stepVisionModel, _stepVisionAnalysis })
            if (s != null && DiagnosticSteps.Contains(s)) DiagnosticSteps.Remove(s);
        _stepPlay = _stepScreenshot = _stepLlm = _stepNameAlert = null;
        _stepVisionModel = _stepVisionAnalysis = null;
    }

    private void OnAudioLevelUpdated(object? sender, float rms)
    {
        _lastAudioRms = rms;

        // Natural silence (RMS < 0.005) = a sentence boundary moment: the server will detect this
        // pause and emit a result on its own. Reset the watchdog boundary timer so it doesn't also
        // force a reconnect for the next speech segment.
        if (rms < 0.005f)
            _lastSpeechBoundaryAt = DateTime.UtcNow;

        if ((_stepAudio?.State == DiagState.Running || _stepAudio?.State == DiagState.Warning) && rms > 0.005f)
        {
            _audioSignalReceived = true;
            _audioCheckTimer?.Stop();
            _stepAudio.SetOk(LocalizationManager.Format("FloatAudioLevelFmt", rms));
            if (DiagnosticHint == LocalizationManager.Get("FloatNoAudioHint"))
                DiagnosticHint = string.Empty;
            TryAutoHideDiagnostics();
        }
        else if (_stepAudio?.State == DiagState.OK)
        {
            // Update the level display while monitoring (throttled — the level event
            // fires per audio frame, far too often for a UI text update).
            var now = DateTime.UtcNow;
            if ((now - _lastAudioDetailUpdateAt).TotalMilliseconds >= 200)
            {
                _lastAudioDetailUpdateAt = now;
                _stepAudio.Detail = LocalizationManager.Format("FloatAudioLevelFmt", rms);
            }
        }
    }

    private void TryAutoHideDiagnostics()
    {
        if (_stepDevice?.State     == DiagState.OK &&
            _stepAsr?.State        == DiagState.OK &&
            _stepAudio?.State      == DiagState.OK &&
            _stepTranscript?.State == DiagState.OK)
        {
            // Auto-hide after 5 s so user can confirm all green
            _ = Task.Delay(5_000).ContinueWith(_ =>
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    // Re-check: a warning may have appeared during the 5 s window
                    if (_stepDevice?.State     == DiagState.OK &&
                        _stepAsr?.State        == DiagState.OK &&
                        _stepAudio?.State      == DiagState.OK &&
                        _stepTranscript?.State == DiagState.OK)
                        IsDiagnosticVisible = false;
                }));
        }
    }

    // ── Elapsed timer ─────────────────────────────────────────────────────

    private DateTime _lastAudioDetailUpdateAt = DateTime.MinValue;

    // ── Manual alert trigger ─────────────────────────────────────────────

    private bool CanManualTriggerAlert() => IsMonitoring && !IsManualAlertRunning;

    [RelayCommand(CanExecute = nameof(CanManualTriggerAlert))]
    private async Task ManualTriggerAlertAsync()
    {
        IsManualAlertRunning = true;
        try
        {
            // Collect recent context (up to 2 minutes / 16 segments)
            List<(DateTime Time, string Text)> recent;
            lock (_historyLock)
                recent = _timestampedHistory.TakeLast(16).ToList();

            var contextLines = recent.Select(t => t.Text).ToArray();
            var contextText  = string.Join("\n", contextLines);
            var triggeredAt  = DateTime.Now;

            // Take screenshot immediately
            string? screenshotPath = null;
            try { screenshotPath = await _screenCapture.TakeScreenshotAsync(); }
            catch (Exception ex) { _logger.LogWarning(ex, "[ManualAlert] Screenshot failed"); }

            // Ask LLM to extract what was asked of the user from the recent context
            string[] questions;
            try
            {
                var userName = SecureStorage.Load(SecureStorageKeys.UserName)?.Trim() ?? LocalizationManager.Get("FloatUser");
                var userRole = SecureStorage.Load(SecureStorageKeys.UserRole)?.Trim();
                string prompt;
                if (LocalizationManager.Instance.IsEnglish)
                {
                    var roleHintEn = string.IsNullOrEmpty(userRole) ? string.Empty
                        : $"\nUser role: {userRole}";
                    prompt =
                        $$"""
                        User name: {{userName}}{{roleHintEn}}

                        Below are the most recent meeting transcript lines (one per line):
                        {{contextText}}

                        Extract the most recent questions addressed to this user, or matters requiring this user's response.
                        Return JSON only, format: {"questions":["question1","question2"]}
                        If there is no clear question, return: {"questions":["(Please confirm what was just mentioned)"]}
                        """;
                }
                else
                {
                    var roleHint = string.IsNullOrEmpty(userRole) ? string.Empty
                        : $"\n用户角色：{userRole}";
                    prompt =
                        $$"""
                        用户姓名：{{userName}}{{roleHint}}

                        以下是会议最近的转录文本（每行一条）：
                        {{contextText}}

                        请从上述文本中提取最近向该用户提出的问题或需要该用户回应的事项。
                        只返回JSON，格式：{"questions":["问题1","问题2"]}
                        若没有明确问题，返回：{"questions":["（请确认刚才被提及的内容）"]}
                        """;
                }
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(12));
                var reply     = await _llm.AnalyzeAsync(prompt, cts.Token);
                var j         = System.Text.Json.JsonDocument.Parse(
                    reply[reply.IndexOf('{')..( reply.LastIndexOf('}') + 1)]);
                questions = j.RootElement.GetProperty("questions")
                              .EnumerateArray()
                              .Select(e => e.GetString() ?? string.Empty)
                              .Where(s => s.Length > 0)
                              .ToArray();
                if (questions.Length == 0) throw new InvalidOperationException("empty");
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[ManualAlert] LLM question extraction failed");
                questions = new[] { LocalizationManager.Get("FloatConfirmMentioned") };
            }

            // Pick the most recent transcript line as the "original text"
            var originalText = recent.Count > 0
                ? recent[^1].Text
                : LocalizationManager.Get("FloatManualTrigger");

            _ = Application.Current?.Dispatcher.BeginInvoke(() =>
                NameDetected?.Invoke(originalText, questions, triggeredAt,
                                     contextLines, screenshotPath));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[ManualAlert] Unexpected error");
        }
        finally
        {
            IsManualAlertRunning = false;
        }
    }

    // ── Quick summary (popup + inline) ───────────────────────────────────

    [RelayCommand]
    private async Task ShowQuickSummaryAsync()
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            _quickSummaryPopup.ShowSkeleton();
            IsInlineSummaryLoading = true;
            InlineSummaryText = string.Empty;
        });
        try
        {
            var transcripts = GetRecentTranscripts(100);
            if (transcripts.Count == 0)
            {
                Application.Current?.Dispatcher.Invoke(() =>
                {
                    _quickSummaryPopup.ShowContent(CurrentTopic, LocalizationManager.Get("FloatNoMeetingContent"), Array.Empty<string>());
                    IsInlineSummaryLoading = false;
                    InlineSummaryText = LocalizationManager.Get("FloatNoTranscriptYet");
                });
                return;
            }

            var role               = SecureStorage.Load(SecureStorageKeys.UserRole);
            var screenshotSummaries = _contextManager?.BuildContext().ScreenshotSummaries;
            var prompt = BuildSummaryPrompt(transcripts, detailed: true, userRole: role,
                screenshotSummaries: screenshotSummaries);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var response = await _llm.AnalyzeAsync(prompt, cts.Token);
            ParseSummaryJson(response, out var summary, out var newDecisions, out var newActions);

            // Merge freshly detected decisions
            if (newDecisions.Length > 0)
            {
                lock (_decisionsLock)
                {
                    foreach (var d in newDecisions)
                        if (!_currentDecisions.Contains(d, StringComparer.OrdinalIgnoreCase))
                            _currentDecisions.Add(d);
                }
                if (_currentTopicId.HasValue)
                {
                    var topicId = _currentTopicId.Value;
                    _ = Task.Run(() => SaveDecisionsAsync(
                        topicId, newDecisions.ToList()));
                }
            }

            // Merge freshly detected action items
            if (newActions.Length > 0)
            {
                lock (_actionItemsLock)
                {
                    foreach (var a in newActions)
                        if (!_currentActionItems.Any(x => x.Task.Equals(a.Task, StringComparison.OrdinalIgnoreCase)))
                            _currentActionItems.Add(a);
                }
                if (_currentTopicId.HasValue)
                {
                    var topicId = _currentTopicId.Value;
                    _ = Task.Run(() => SaveActionItemsAsync(topicId, newActions.ToList()));
                }
            }

            string[] allDecisions;
            string[] allActionStrings;
            lock (_decisionsLock)   allDecisions     = _currentDecisions.ToArray();
            var isEnUi = LocalizationManager.Instance.IsEnglish;
            lock (_actionItemsLock) allActionStrings = _currentActionItems
                .Select(a => string.IsNullOrEmpty(a.Deadline)
                    ? (isEnUi ? $"{a.AssignedTo}: {a.Task}" : $"{a.AssignedTo}：{a.Task}")
                    : (isEnUi ? $"{a.AssignedTo}: {a.Task} ({a.Deadline})" : $"{a.AssignedTo}：{a.Task}（{a.Deadline}）"))
                .ToArray();

            Application.Current?.Dispatcher.Invoke(() =>
            {
                _quickSummaryPopup.ShowContent(CurrentTopic, summary, allDecisions, allActionStrings);
                IsInlineSummaryLoading = false;
                InlineSummaryText = summary;
            });
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "ShowQuickSummary failed");
            var errMsg = LocalizationManager.Format("FloatSummaryFailFmt", ex.Message);
            Application.Current?.Dispatcher.Invoke(() =>
            {
                _quickSummaryPopup.ShowContent(CurrentTopic, errMsg, Array.Empty<string>());
                IsInlineSummaryLoading = false;
                InlineSummaryText = errMsg;
            });
        }
    }

    private async Task RefreshInlineSummaryAsync()
    {
        var transcripts = GetRecentTranscripts(50);
        if (transcripts.Count < 5) return;

        _ = Application.Current?.Dispatcher.BeginInvoke(() => IsInlineSummaryLoading = true);
        try
        {
            var role               = SecureStorage.Load(SecureStorageKeys.UserRole);
            var screenshotSummaries = _contextManager?.BuildContext().ScreenshotSummaries;
            var prompt = BuildSummaryPrompt(transcripts, detailed: false, userRole: role,
                screenshotSummaries: screenshotSummaries);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var response = await _llm.AnalyzeAsync(prompt, cts.Token);
            ParseSummaryJson(response, out var summary, out _, out _);
            _ = Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                InlineSummaryText      = summary;
                IsInlineSummaryLoading = false;
            });
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "RefreshInlineSummary failed");
            _ = Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                IsInlineSummaryLoading = false;
                InlineSummaryText = LocalizationManager.Format("FloatSummaryFailBracketFmt", ex.Message);
            });
        }
    }

    private static string BuildSummaryPrompt(IReadOnlyList<string> transcripts, bool detailed,
                                              string? userRole = null,
                                              IReadOnlyList<ScreenshotSummary>? screenshotSummaries = null)
    {
        var joined   = string.Join("\n", transcripts);
        var screenshotSection = BuildScreenshotSection(screenshotSummaries);

        if (LocalizationManager.Instance.IsEnglish)
        {
            var roleHintEn = string.IsNullOrWhiteSpace(userRole) ? string.Empty
                : $"\n(Current user role: {userRole} — pay special attention to content related to this role in the summary and action items)";

            return detailed
                ? $$"""
                   Analyze the following meeting transcript and return JSON in this format:
                   {"summary":"key-points summary (2-5 sentences)","decisions":["decision1","decision2"],"actions":[{"assignedTo":"owner","task":"specific task","deadline":"deadline or null"}]}

                   decisions: only explicit decisions; actions: only action items with a clear owner.
                   Return empty arrays if none. Return JSON only, no Markdown.{{roleHintEn}}

                   Transcript:
                   {{joined}}
                   {{screenshotSection}}
                   """
                : $$"""
                   Summarize the key points of the following meeting discussion in 2-3 sentences, returned as JSON:
                   {"summary":"brief summary","decisions":[],"actions":[]}

                   Return JSON only, no Markdown.{{roleHintEn}}

                   Transcript:
                   {{joined}}
                   {{screenshotSection}}
                   """;
        }

        var roleHint = string.IsNullOrWhiteSpace(userRole) ? string.Empty
            : $"\n（当前用户角色：{userRole}，请在摘要和行动项中特别关注与该角色相关的内容）";

        return detailed
            ? $$"""
               请分析以下会议转录内容，以JSON格式返回，格式：
               {"summary":"要点摘要（2-5句话）","decisions":["决策1","决策2"],"actions":[{"assignedTo":"负责人","task":"具体任务","deadline":"截止时间或null"}]}

               decisions 只放明确的决策结论；actions 只放有明确负责人的行动项。
               若无则返回空数组。只返回JSON，不要Markdown标记。{{roleHint}}

               转录内容：
               {{joined}}
               {{screenshotSection}}
               """
            : $$"""
               请用2-3句话总结以下会议讨论要点，以JSON格式返回：
               {"summary":"简短摘要","decisions":[],"actions":[]}

               只返回JSON，不要Markdown标记。{{roleHint}}

               转录内容：
               {{joined}}
               {{screenshotSection}}
               """;
    }

    private static string BuildScreenshotSection(IReadOnlyList<ScreenshotSummary>? screenshots)
    {
        if (screenshots is null or { Count: 0 }) return string.Empty;
        var sb = new System.Text.StringBuilder();
        sb.AppendLine();
        sb.AppendLine(LocalizationManager.Instance.IsEnglish
            ? "[Screenshot Content Analysis] (content shown on screen during the meeting)"
            : "【截图内容分析】（会议期间屏幕展示的内容）");
        foreach (var s in screenshots)
            sb.AppendLine($"[{s.TimeLabel}] {s.AiSummary}");
        return sb.ToString();
    }

    private static void ParseSummaryJson(string json, out string summary, out string[] decisions,
                                         out (string AssignedTo, string Task, string? Deadline)[] actions)
    {
        try
        {
            var start = json.IndexOf('{');
            var end   = json.LastIndexOf('}');
            if (start >= 0 && end > start)
                json = json[start..(end + 1)];

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            summary = root.TryGetProperty("summary", out var s)
                ? s.GetString() ?? string.Empty
                : string.Empty;

            var dec = new List<string>();
            if (root.TryGetProperty("decisions", out var d) && d.ValueKind == JsonValueKind.Array)
                foreach (var item in d.EnumerateArray())
                    if (item.GetString() is string text && !string.IsNullOrWhiteSpace(text))
                        dec.Add(text);
            decisions = dec.ToArray();

            var act = new List<(string, string, string?)>();
            if (root.TryGetProperty("actions", out var a) && a.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in a.EnumerateArray())
                {
                    var assignedTo = item.TryGetProperty("assignedTo", out var at) ? at.GetString() ?? string.Empty : string.Empty;
                    var task       = item.TryGetProperty("task",       out var t2) ? t2.GetString() ?? string.Empty : string.Empty;
                    var deadline   = item.TryGetProperty("deadline",   out var dl) && dl.ValueKind != JsonValueKind.Null
                                     ? dl.GetString() : null;
                    if (!string.IsNullOrWhiteSpace(task))
                        act.Add((assignedTo, task, deadline));
                }
            }
            actions = act.ToArray();
        }
        catch
        {
            summary   = json;
            decisions = Array.Empty<string>();
            actions   = Array.Empty<(string, string, string?)>();
        }
    }

    // ── Screenshot album ──────────────────────────────────────────────────

    [RelayCommand]
    private void OpenScreenshotAlbum()
    {
        _screenshotAlbumWindow.Show();
        _screenshotAlbumWindow.Activate();
    }

    // ── Capture window picker ─────────────────────────────────────────────

    [ObservableProperty] private string _captureWindowTitle = string.Empty;
    private bool _pendingStartAfterWindowSelect;
    private CancellationTokenSource? _windowEnumDebounceCts;

    partial void OnCaptureWindowTitleChanged(string value)
    {
        // Typing never auto-starts — only an explicit dropdown selection does
        // (OnWindowExplicitlySelected). Clearing the text cancels a pending start.
        if (string.IsNullOrWhiteSpace(value))
            _pendingStartAfterWindowSelect = false;

        // Debounce the EnumWindows refresh so each keystroke doesn't re-enumerate.
        var cts  = new CancellationTokenSource();
        var prev = Interlocked.Exchange(ref _windowEnumDebounceCts, cts);
        prev?.Cancel();
        prev?.Dispose();
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(300, cts.Token);
                System.Windows.Application.Current?.Dispatcher.Invoke(RefreshWindows);
            }
            catch (OperationCanceledException) { }
        });
    }

    /// <summary>Cancels a pending auto-start (e.g. user pressed Esc).</summary>
    public void CancelPendingStart() => _pendingStartAfterWindowSelect = false;

    /// <summary>Called by the view when the user explicitly picks a window from the
    /// dropdown. Starts listening only if a start was requested earlier.</summary>
    public void OnWindowExplicitlySelected(string title)
    {
        CaptureWindowTitle = title;
        if (_pendingStartAfterWindowSelect
            && FindWindowByTitle(title, exact: true) != IntPtr.Zero)
        {
            _pendingStartAfterWindowSelect = false;
            _ = StartListeningCommand.ExecuteAsync(null);
        }
    }

    public ObservableCollection<string> AvailableWindows { get; } = new();

    [RelayCommand]
    private void RefreshWindows()
    {
        AvailableWindows.Clear();
        var titles  = new List<string>();
        var ownPid  = (uint)Environment.ProcessId;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == ownPid) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hwnd, sb, 256);
            var title = sb.ToString().Trim();
            if (title.Length > 1 && !title.Equals("MeetingQ", StringComparison.Ordinal))
                titles.Add(title);
            return true;
        }, IntPtr.Zero);
        foreach (var t in titles.Distinct().OrderBy(x => x))
            AvailableWindows.Add(t);
    }

    // ── Window-capture helpers ─────────────────────────────────────────────

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMax);
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    private static IntPtr FindWindowByTitle(string title, bool exact = false)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hwnd, sb, 256);
            var windowTitle = sb.ToString();
            var match = exact
                ? windowTitle.Equals(title, StringComparison.OrdinalIgnoreCase)
                : windowTitle.Contains(title, StringComparison.OrdinalIgnoreCase);
            if (match)
            { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private async Task SaveScreenshotAsync(int sessionId, int? topicId, ScreenshotCapturedEventArgs e)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();
            db.Screenshots.Add(new Screenshot
            {
                SessionId      = sessionId,
                RelatedTopicId = topicId,
                FilePath       = e.FilePath,
                Timestamp      = e.Timestamp,
                ImageHash      = e.ImageHash
            });
            await db.SaveChangesAsync();
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to save screenshot"); }
    }

    // ── ASR error handler ─────────────────────────────────────────────────

    private void OnAsrError(object? sender, string message)
    {
        _logger.LogError("[ASR] Server error: {Msg}", message);

        bool isAuthError = message.Contains("4001") || message.Contains("4003") || message.Contains("401");

        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            _stepAsr?.SetError(message);
            _stepTranscript?.SetError(LocalizationManager.Get("FloatAsrServerError"));
            DiagnosticHint = isAuthError
                ? LocalizationManager.Get("FloatAsrAuthHint")
                : LocalizationManager.Get("FloatAsrReconnectingHint");
            IsDiagnosticVisible = true;
            StatusText = LocalizationManager.Get("FloatAsrError");
        });

        // For non-auth errors while monitoring, attempt to re-establish the connection.
        // Auth errors are not retried — the user must fix their credentials first.
        if (!isAuthError && IsMonitoring && Interlocked.Exchange(ref _asrReconnecting, 1) == 0)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(1000); // brief backoff
                    if (!IsMonitoring) return; // session stopped during backoff
                    // FinalizeSegmentAsync handles the full reconnect cycle including
                    // draining _pendingAudio queued during the dead window.
                    await _asr.FinalizeSegmentAsync();
                    _logger.LogInformation("[ASR] Reconnected after server error");
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        _stepAsr?.SetOk(LocalizationManager.Get("FloatReconnected"));
                        DiagnosticHint = string.Empty;
                        StatusText = LocalizationManager.Get("FloatListening");
                    });
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "[ASR] Reconnect after error failed");
                }
                finally
                {
                    Interlocked.Exchange(ref _asrReconnecting, 0);
                }
            });
        }
    }

    // ── Transcript handler ────────────────────────────────────────────────

    private void OnTranscriptReceived(object? sender, TranscriptEventArgs e)
    {
        // Complete the self-test TCS on first non-empty result
        if (IsSelfTestRunning && _selfTestTranscriptTcs != null && !string.IsNullOrWhiteSpace(e.Text))
            _selfTestTranscriptTcs.TrySetResult(e.Text);

        string displayText;
        string? committedText = null;   // set when a full sentence is sealed
        lock (_historyLock)
        {
            // ── Sentence boundary detection ──────────────────────────────────
            // Primary path: ASR service signals isFinal=true for each confirmed sentence
            // (AST sentence result with msgtype=sentence).
            // In that case e.Text IS the complete sentence — commit it directly.
            //
            // Fallback: isFinal=false rolling partials (no definite signal). Use heuristics
            // (uid change, length reset, content change) to detect sentence boundaries.

            if (e.IsFinal)
            {
                // Definite sentence — commit e.Text directly.
                // Discard _lastAsrText (it was an in-progress partial of this sentence).
                if (!string.IsNullOrWhiteSpace(e.Text))
                {
                    committedText = e.Text;
                    _transcriptHistory.Add(e.Text);
                    _timestampedHistory.Add((DateTime.Now, e.Text));
                    if (_transcriptHistory.Count > 200) _transcriptHistory.RemoveAt(0);
                    if (_timestampedHistory.Count > 60)  _timestampedHistory.RemoveAt(0);
                    AppLog.Info("FloatingWindowViewModel", $"[TXN] COMMITTED (definite) '{e.Text}'");
                }
                _lastAsrText        = string.Empty;
                // Reset to -1 so the next partial's uid doesn't trigger a false uid-change commit.
                // The server resets its utterance counter after each definite boundary, so the
                // partial after an isFinal will have a uid that appears "changed" from the
                // definite's uid even though no sentence boundary actually occurred.
                _lastAsrUtteranceId = -1;
            }
            else
            {
                // Rolling partial — use heuristics to detect sentence boundary.
                // Fallback for services without isFinal signaling (e.g. no utterances[] array).
                //
                // contentChanged is intentionally excluded: streaming ASR servers often
                // corrects punctuation mid-sentence (e.g. 。→！), causing contentChanged to
                // commit a wrong mid-sentence fragment. lengthReset and uidChanged are
                // sufficient for real boundaries (new sentence starts shorter or resets uid).
                bool uidChanged  = e.UtteranceId >= 0 && _lastAsrUtteranceId >= 0
                                   && e.UtteranceId != _lastAsrUtteranceId;
                // Require >50% length drop to avoid false commits from mid-sentence corrections
                // (ASR servers often produce shorter text when correcting punctuation or words).
                bool lengthReset = _lastAsrText.Length > 10 && e.Text.Length < _lastAsrText.Length * 0.5;

                string commitReason = uidChanged    ? $"uid-change({_lastAsrUtteranceId}→{e.UtteranceId})"
                                    : lengthReset   ? $"length-reset({_lastAsrText.Length}→{e.Text.Length})"
                                    : string.Empty;

                bool shouldCommit = uidChanged || lengthReset;

                AppLog.Info("FloatingWindowViewModel",
                    $"[TXN] uid={e.UtteranceId} isFinal=false len={e.Text.Length} prevLen={_lastAsrText.Length} " +
                    $"commit={shouldCommit} reason={commitReason} text='{e.Text}'");

                if (shouldCommit && !string.IsNullOrWhiteSpace(_lastAsrText))
                {
                    committedText = _lastAsrText;
                    _transcriptHistory.Add(_lastAsrText);
                    _timestampedHistory.Add((DateTime.Now, _lastAsrText));
                    if (_transcriptHistory.Count > 200) _transcriptHistory.RemoveAt(0);
                    if (_timestampedHistory.Count > 60)  _timestampedHistory.RemoveAt(0);
                    AppLog.Info("FloatingWindowViewModel", $"[TXN] COMMITTED (heuristic:{commitReason}) '{committedText}'");
                    _lastAsrText        = e.Text;
                    _lastAsrUtteranceId = e.UtteranceId;
                }
                else
                {
                    _lastAsrText        = e.Text;
                    _lastAsrUtteranceId = e.UtteranceId;
                }
            }

            // Display: last 25 committed segments + current in-progress text at bottom
            var lines = _transcriptHistory.TakeLast(25).ToList();
            if (!string.IsNullOrWhiteSpace(_lastAsrText))
                lines.Add(_lastAsrText);
            displayText = string.Join("\n", lines);
        }

        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            LatestTranscript = displayText);

        // Reset both watchdog timestamps — a successful transcript is a valid sentence boundary.
        _lastTranscriptAt     = DateTime.UtcNow;
        _lastSpeechBoundaryAt = DateTime.UtcNow;

        // Mark transcript diagnostic as OK on first result
        if (!_transcriptReceived)
        {
            _transcriptReceived = true;
            _transcriptCheckTimer?.Stop();
            _stepTranscript?.SetOk(LocalizationManager.Get("FloatTranscriptOk"));
            DiagnosticHint = string.Empty;
            TryAutoHideDiagnostics();
        }

        // Persist to SQLite only when a complete sentence is sealed (cumulative segment reset).
        // This prevents saving every intermediate update ("记得", "记得上次", "记得上次会上你…").
        // Read the topic id under _topicLock so a mid-switch transcript never lands in a
        // half-closed topic (CloseCurrentTopicAsync → CreateNewTopicAsync holds the lock).
        int? currentTopicId;
        _topicLock.Wait();
        try { currentTopicId = _currentTopicId; }
        finally { _topicLock.Release(); }

        if (committedText != null && currentTopicId.HasValue)
        {
            var topicId      = currentTopicId.Value;
            var committed    = committedText;
            var speakerLabel = e.SpeakerLabel;

            // Track label timeline for screenshot-time alignment (Vision results arrive
            // seconds after the screenshot; the current label may have changed by then).
            if (speakerLabel is not null)
                lock (_speakerTimeline) _speakerTimeline.Add((DateTime.Now, speakerLabel));

            // Trigger screenshot on FIRST encounter of a new unmapped speaker
            if (speakerLabel is not null && speakerLabel != _lastSpeakerLabel)
            {
                _lastSpeakerLabel = speakerLabel;
                bool isNewSpeaker;
                lock (_participantLock)
                    isNewSpeaker = !_speakerNameMap.ContainsKey(speakerLabel)
                                && _pendingSpeakerLabels.Add(speakerLabel);
                if (_screenCapture?.IsCapturing == true
                    && isNewSpeaker
                    && (DateTime.Now - _lastSpeakerScreenshotAt).TotalSeconds >= 10) // cooldown for rapid speaker alternation
                {
                    _lastSpeakerScreenshotAt = DateTime.Now;
                    _ = Task.Run(async () =>
                    {
                        try { await _screenCapture.TakeScreenshotAsync(); }
                        catch (Exception ex) { AppLog.Error("FloatingWindowViewModel", "[Speaker] Screenshot trigger failed", ex); }
                    });
                }
            }

            _ = Task.Run(() => SaveTranscriptAsync(topicId,
                new TranscriptEventArgs(committed, isFinal: true, confidence: 1.0f,
                    speakerLabel: speakerLabel)));
            _contextManager?.AddTranscript(committed);
        }

        // Name detection: only run on committed (isFinal) sentences.
        // Streaming partials update every ~300ms per character — running name detection on
        // each would flood the LLM with concurrent requests, causing multi-second delays.
        if (!e.IsFinal) return;

        // Name detection
        _ = Task.Run(async () =>
        {
            try
            {
                var result = await _nameDetection.DetectAsync(e.Text);
                if (!result.IsDetected) return;

                // Update transcript with detected speaker name
                if (!string.IsNullOrWhiteSpace(result.MatchedName) && _currentTopicId.HasValue)
                {
                    var topicId = _currentTopicId.Value;
                    _ = Task.Run(() => UpdateTranscriptSpeakerAsync(
                        topicId, e.Text, result.MatchedName!));
                }

                // 5-second cooldown to suppress alert flooding
                var now = DateTime.Now;
                if ((now - _lastNameAlertFiredAt).TotalSeconds < 5)
                {
                    _logger.LogDebug("[NameDetect] Alert suppressed (cooldown)");
                    return;
                }
                _lastNameAlertFiredAt = now;

                var questions = result.ExtractedQuestions is { Length: > 0 }
                    ? result.ExtractedQuestions
                    : new[] { e.Text };

                // Grab preceding transcripts (up to 8) as 1-minute context
                string[] contextLines;
                lock (_historyLock)
                {
                    var count = _timestampedHistory.Count;
                    // exclude the last entry (that's the current transcript we just added)
                    var beforeCount = Math.Max(0, count - 1);
                    contextLines = _timestampedHistory
                        .Skip(Math.Max(0, beforeCount - 8))
                        .Take(Math.Min(beforeCount, 8))
                        .Select(t => t.Text)
                        .ToArray();
                }

                // Capture a screenshot at the moment the name was called
                string? screenshotPath = null;
                try { if (_screenCapture is not null) screenshotPath = await _screenCapture.TakeScreenshotAsync(); }
                catch (Exception ex) { _logger.LogWarning(ex, "[NameDetect] Screenshot failed"); }

                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    NameDetected?.Invoke(e.Text, questions, now, contextLines, screenshotPath));
            }
            catch (Exception ex) { _logger.LogWarning(ex, "Name detection error"); }
        });

        // Topic auto-detection every 20 transcripts
        if (++_transcriptsSinceTopicCheck >= 20 && !_topicDetecting)
            _ = Task.Run(DetectTopicAsync);

        // Conclusion auto-detection every 25 transcripts
        if (++_transcriptsSinceConclusionCheck >= 25 && !_conclusionDetecting)
            _ = Task.Run(DetectConclusionsAsync);
    }

    // ── Topic detection ───────────────────────────────────────────────────

    private async Task DetectTopicAsync()
    {
        if (_topicDetecting) return;
        _topicDetecting             = true;
        _transcriptsSinceTopicCheck = 0;

        try
        {
            var recent = GetRecentTranscripts(30);
            if (recent.Count < 5) { _topicDetecting = false; return; }

            var prompt = LocalizationManager.Instance.IsEnglish
                ? $"Based on the following meeting dialogue, summarize the core topic currently being discussed in no more than 6 words; return only the topic name:\n{string.Join("\n", recent)}"
                : $"根据以下会议对话，用不超过10个字总结当前讨论的核心议题，只返回议题名称：\n{string.Join("\n", recent)}";
            var topic  = (await _llm.AnalyzeAsync(prompt)).Trim().Trim('"').Trim('。').Trim();

            if (string.IsNullOrWhiteSpace(topic) || topic.Length > 20) { _topicDetecting = false; return; }

            _logger.LogInformation("[Topic] Detected: {Topic}", topic);

            var current = CurrentTopic?.Trim() ?? string.Empty;

            // First detection: update the existing placeholder topic
            if (string.IsNullOrEmpty(current))
            {
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => CurrentTopic = topic);
                _contextManager?.SetCurrentTopic(topic);

                if (_currentTopicId.HasValue)
                {
                    var topicId = _currentTopicId.Value;
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            using var db = _dbFactory.CreateDbContext();
                            var t = await db.Topics.FindAsync(topicId);
                            if (t is not null) { t.Title = topic; await db.SaveChangesAsync(); }
                        }
                        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to update topic"); }
                    });
                }
            }
            // Topic changed: close current, create new
            else if (!string.Equals(current, topic, StringComparison.OrdinalIgnoreCase))
            {
                _ = Task.Run(async () =>
                {
                    // Serialized with transcript commit (OnTranscriptReceived) via _topicLock
                    // so no transcript lands in a half-closed topic during the switch.
                    await _topicLock.WaitAsync();
                    try
                    {
                        await CloseCurrentTopicAsync();
                        await CreateNewTopicAsync(topic);
                    }
                    catch (Exception ex) { _logger.LogWarning(ex, "[Topic] Transition failed"); }
                    finally { _topicLock.Release(); }
                });

                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => CurrentTopic = topic);
                _contextManager?.SetCurrentTopic(topic);
                _transcriptsSinceTopicCheck = 0;
            }
            // Same topic: no-op
        }
        catch (Exception ex) { _logger.LogWarning(ex, "Topic detection error"); }
        finally { _topicDetecting = false; }
    }

    private async Task CloseCurrentTopicAsync(int? topicIdOverride = null, bool waitForSummary = false)
    {
        var topicId = topicIdOverride ?? _currentTopicId;
        if (!topicId.HasValue) return;

        var tid = topicId.Value;
        try
        {
            using var db = _dbFactory.CreateDbContext();
            var t = await db.Topics.FindAsync(tid);
            if (t is not null)
            {
                t.EndTime = DateTime.Now;
                await db.SaveChangesAsync();
                _logger.LogInformation("[Topic] Closed: {Title}", t.Title);
            }
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to close topic"); }

        // Generate per-topic summary, optionally wait for completion
        var summaryTask = Task.Run(async () =>
        {
            try
            {
                var summary = await GenerateTopicSummaryAsync(tid);
                if (summary is null) return;
                using var db = _dbFactory.CreateDbContext();
                var t = await db.Topics.FindAsync(tid);
                if (t is not null) { t.Summary = summary; await db.SaveChangesAsync(); }
            }
            catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to save topic summary"); }
        });

        if (waitForSummary)
            await summaryTask;
    }

    private async Task CreateNewTopicAsync(string title)
    {
        if (!_currentSessionId.HasValue) return;

        try
        {
            using var db = _dbFactory.CreateDbContext();

            var maxOrder = await db.Topics
                .Where(t => t.SessionId == _currentSessionId.Value)
                .MaxAsync(t => (int?)t.OrderIndex) ?? -1;

            var topic = new Topic
            {
                SessionId  = _currentSessionId.Value,
                Title      = title,
                StartTime  = DateTime.Now,
                OrderIndex = maxOrder + 1
            };
            db.Topics.Add(topic);
            await db.SaveChangesAsync();

            _currentTopicId = topic.TopicId;
            _logger.LogInformation("[Topic] Created: {Title} (OrderIndex={Order})", title, topic.OrderIndex);
        }
        catch (Exception ex) { _logger.LogError(ex, "[DB] Failed to create topic"); }
    }

    private async Task<string?> GenerateTopicSummaryAsync(int topicId)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();

            var topic = await db.Topics
                .Include(t => t.Transcripts)
                .Include(t => t.Decisions)
                .Include(t => t.ActionItems)
                .FirstOrDefaultAsync(t => t.TopicId == topicId);

            if (topic is null) return null;

            var transcripts = topic.Transcripts.OrderBy(tr => tr.Timestamp).Select(tr => tr.Text).ToList();
            if (transcripts.Count < 3) return null;

            var screenshots = await db.Screenshots
                .Where(s => s.SessionId == topic.SessionId
                    && s.AnalysisStatus == "ready"
                    && (s.RelatedTopicId == topicId
                        || (s.Timestamp >= topic.StartTime
                            && (topic.EndTime == null || s.Timestamp <= topic.EndTime))))
                .OrderBy(s => s.Timestamp)
                .ToListAsync();

            var prompt = BuildTopicSummaryPrompt(topic, transcripts, topic.Decisions.ToList(),
                topic.ActionItems.ToList(), screenshots);

            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var response = await _llm.AnalyzeAsync(prompt, cts.Token);
            ParseSummaryJson(response, out var summary, out _, out _);
            return summary;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Topic] Summary generation failed for topic {Id}", topicId);
            return null;
        }
    }

    private static string BuildTopicSummaryPrompt(Topic topic, List<string> transcripts,
        List<Decision> decisions, List<ActionItem> actions, List<Screenshot> screenshots)
    {
        var sb = new System.Text.StringBuilder();
        var isEn = LocalizationManager.Instance.IsEnglish;

        sb.AppendLine(isEn
            ? "You are a meeting-minutes assistant. Generate a concise summary for the following meeting topic. Respond in English."
            : "你是会议记录助手。请为以下会议议题生成简洁摘要。");
        sb.AppendLine();
        sb.AppendLine(isEn
            ? $"Topic title: {topic.Title}"
            : $"议题标题：{topic.Title}");
        sb.AppendLine(isEn
            ? $"Time range: {topic.StartTime:HH:mm} - {(topic.EndTime?.ToString("HH:mm") ?? "now")}"
            : $"时间范围：{topic.StartTime:HH:mm} - {(topic.EndTime?.ToString("HH:mm") ?? "至今")}");
        sb.AppendLine();
        sb.AppendLine(isEn ? "[Transcript]" : "【对话转录】");
        sb.AppendLine(string.Join("\n", transcripts));
        sb.AppendLine();

        if (decisions.Count > 0)
        {
            sb.AppendLine(isEn ? "[Related decisions]" : "【相关决策】");
            foreach (var d in decisions)
                sb.AppendLine($"- {d.DecisionText}");
            sb.AppendLine();
        }

        if (actions.Count > 0)
        {
            sb.AppendLine(isEn ? "[Related action items]" : "【相关行动项】");
            foreach (var a in actions)
                sb.AppendLine($"- {a.AssignedTo}: {a.Task}" + (a.Deadline is not null ? $" ({a.Deadline})" : ""));
            sb.AppendLine();
        }

        if (screenshots.Count > 0)
        {
            sb.AppendLine(isEn ? "[Screen content analysis]" : "【屏幕内容分析】");
            foreach (var s in screenshots.Take(5))
            {
                var summary = s.AISummary ?? "";
                var ocr = s.OcrText ?? "";
                var type = s.ContentType ?? (isEn ? "Unknown" : "未知");
                sb.AppendLine(isEn
                    ? $"[{s.Timestamp:HH:mm:ss}] Type: {type} | Content: {summary}" +
                      (string.IsNullOrWhiteSpace(ocr) ? "" : $" | OCR: {ocr}")
                    : $"[{s.Timestamp:HH:mm:ss}] 类型：{type} | 内容：{summary}" +
                      (string.IsNullOrWhiteSpace(ocr) ? "" : $" | OCR：{ocr}"));
            }
            sb.AppendLine();
        }

        if (isEn)
        {
            sb.AppendLine("Return JSON in this format:");
            sb.AppendLine("{\"summary\":\"Summarize the core discussion, key conclusions and follow-up actions of this topic in 2-4 sentences\"}");
            sb.AppendLine("Return JSON only, no Markdown.");
        }
        else
        {
            sb.AppendLine("请用JSON格式返回：");
            sb.AppendLine("{\"summary\":\"用2-4句话总结该议题的核心讨论内容、关键结论和后续行动\"}");
            sb.AppendLine("只返回JSON，不要Markdown标记。");
        }

        return sb.ToString();
    }

    // ── Conclusion detection ──────────────────────────────────────────────

    private async Task DetectConclusionsAsync()
    {
        if (_conclusionDetecting) return;
        _conclusionDetecting             = true;
        _transcriptsSinceConclusionCheck = 0;

        try
        {
            var recent = GetRecentTranscripts(40);
            if (recent.Count < 8) return;

            var prompt = LocalizationManager.Instance.IsEnglish
                ? $$"""
                    Extract explicit decisions and action items with a clear owner from the following meeting dialogue, returned as JSON:
                    {"decisions":["decision1"],"actions":[{"assignedTo":"owner","task":"task","deadline":"deadline or null"}]}
                    Return empty arrays if none. Return JSON only, no Markdown.

                    Transcript:
                    {{string.Join("\n", recent)}}
                    """
                : $$"""
                    从以下会议对话中提取明确的决策结论和有明确负责人的行动项，以JSON格式返回：
                    {"decisions":["决策1"],"actions":[{"assignedTo":"负责人","task":"任务","deadline":"截止时间或null"}]}
                    若无则返回空数组。只返回JSON，不要Markdown。

                    转录内容：
                    {{string.Join("\n", recent)}}
                    """;

            var response = await _llm.AnalyzeAsync(prompt);
            ParseSummaryJson(response, out _, out var decisions, out var actions);

            // Merge new decisions
            if (decisions.Length > 0)
            {
                List<string> newOnes;
                lock (_decisionsLock)
                {
                    newOnes = decisions
                        .Where(d => !_currentDecisions.Contains(d, StringComparer.OrdinalIgnoreCase))
                        .ToList();
                    _currentDecisions.AddRange(newOnes);
                    if (_currentDecisions.Count > 50)
                        _currentDecisions.RemoveRange(0, _currentDecisions.Count - 50);
                    foreach (var d in newOnes)
                        _contextManager?.AddDecision(d);
                }
                if (newOnes.Count > 0 && _currentTopicId.HasValue)
                {
                    var topicId = _currentTopicId.Value;
                    _ = Task.Run(() => SaveDecisionsAsync(topicId, newOnes));
                    _logger.LogInformation("[Conclusion] Detected {Count} new decisions", newOnes.Count);
                }
            }

            // Merge new action items
            if (actions.Length > 0)
            {
                List<(string AssignedTo, string Task, string? Deadline)> newActs;
                lock (_actionItemsLock)
                {
                    newActs = actions
                        .Where(a => !_currentActionItems.Any(x => x.Task.Equals(a.Task, StringComparison.OrdinalIgnoreCase)))
                        .ToList();
                    _currentActionItems.AddRange(newActs);
                    if (_currentActionItems.Count > 30)
                        _currentActionItems.RemoveRange(0, _currentActionItems.Count - 30);
                    foreach (var a in newActs)
                        _contextManager?.AddActionItem(a.Task, a.AssignedTo, a.Deadline);
                }
                if (newActs.Count > 0 && _currentTopicId.HasValue)
                {
                    var topicId = _currentTopicId.Value;
                    _ = Task.Run(() => SaveActionItemsAsync(topicId, newActs));
                    _logger.LogInformation("[Conclusion] Detected {Count} new action items", newActs.Count);
                }
            }
        }
        catch (Exception ex) { _logger.LogWarning(ex, "Conclusion detection error"); }
        finally { _conclusionDetecting = false; }
    }

    private async Task SaveDecisionsAsync(int topicId, List<string> decisions)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();
            foreach (var text in decisions)
            {
                db.Decisions.Add(new Decision
                {
                    TopicId      = topicId,
                    DecisionText = text,
                    Timestamp    = DateTime.Now
                });
            }
            await db.SaveChangesAsync();
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to save decisions"); }
    }

    private async Task SaveActionItemsAsync(int topicId,
        IEnumerable<(string AssignedTo, string Task, string? Deadline)> items)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();
            foreach (var (assignedTo, task, deadline) in items)
            {
                db.ActionItems.Add(new ActionItem
                {
                    TopicId    = topicId,
                    AssignedTo = assignedTo,
                    Task       = task,
                    Deadline   = deadline,
                    Timestamp  = DateTime.Now
                });
            }
            await db.SaveChangesAsync();
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to save action items"); }
    }

    // ── DB helpers ────────────────────────────────────────────────────────

    private async Task CreateSessionAsync(DateTime startTime)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();

            var session = new MeetingSession
            {
                StartTime = startTime,
                Status    = SessionStatus.Monitoring,
                Title     = LocalizationManager.Format("MeetingTitleFmt", startTime)
            };
            db.Sessions.Add(session);
            await db.SaveChangesAsync();

            var topic = new Topic
            {
                SessionId  = session.SessionId,
                Title      = LocalizationManager.Format("TopicN", 1),
                StartTime  = startTime,
                OrderIndex = 0
            };
            db.Topics.Add(topic);
            await db.SaveChangesAsync();

            _currentSessionId = session.SessionId;
            _currentTopicId   = topic.TopicId;
        }
        catch (Exception ex) { _logger.LogError(ex, "[DB] Failed to create session"); }
    }

    private async Task SaveTranscriptAsync(int topicId, TranscriptEventArgs e)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();
            db.Transcripts.Add(new Transcript
            {
                TopicId    = topicId,
                Text       = e.Text,
                Timestamp  = DateTime.Now,
                IsFinal    = e.IsFinal,
                Confidence = e.Confidence,
                Speaker    = e.SpeakerLabel
            });
            await db.SaveChangesAsync();
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to save transcript"); }
    }

    private async Task UpdateTranscriptSpeakerAsync(int topicId, string text, string speaker)
    {
        try
        {
            using var db = _dbFactory.CreateDbContext();
            var transcript = await db.Transcripts
                .Where(t => t.TopicId == topicId && t.Text == text)
                .OrderByDescending(t => t.TranscriptId)
                .FirstOrDefaultAsync();
            if (transcript is not null)
            {
                transcript.Speaker = speaker;
                await db.SaveChangesAsync();
            }
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[DB] Failed to update transcript speaker"); }
    }

    private async Task EndSessionAsync(int sessionId, int? finalTopicId,
        Dictionary<string, string> realtimeSpeakerMap, int? participantCountHint)
    {
        // Close the last topic first, wait for its summary to complete
        if (finalTopicId.HasValue)
            await CloseCurrentTopicAsync(finalTopicId.Value, waitForSummary: true);

        try
        {
            using var db = _dbFactory.CreateDbContext();

            var session = await db.Sessions.FindAsync(sessionId);
            if (session is null) return;

            // Wait for in-flight Vision analyses so the final summary can use them
            var pendingVision = _pendingVisionTasks.Keys.ToArray();
            if (pendingVision.Length > 0)
            {
                _logger.LogInformation("[Session] Waiting for {Count} pending Vision analyses before summary", pendingVision.Length);
                var waitAll = Task.WhenAll(pendingVision);
                var timeout = Task.Delay(TimeSpan.FromSeconds(20));
                if (await Task.WhenAny(waitAll, timeout) == timeout)
                    _logger.LogWarning("[Session] Timed out waiting for Vision analyses; proceeding without them");
            }

            // Load all topics with related data
            var topics = await db.Topics
                .Include(t => t.Transcripts)
                .Include(t => t.Decisions)
                .Include(t => t.ActionItems)
                .Where(t => t.SessionId == sessionId)
                .OrderBy(t => t.OrderIndex)
                .ToListAsync();

            var screenshots = await db.Screenshots
                .Where(s => s.SessionId == sessionId && s.AnalysisStatus == "ready")
                .OrderBy(s => s.Timestamp)
                .ToListAsync();

            // ── Offline speaker refinement over the meeting recording ──
            // Higher-accuracy diarization pass; corrects real-time mislabels before
            // the OCR-based name mapping runs below.
            SpeakerRefinementContext? refineCtx = null;
            if (_asr is ISpeakerRefinement refinement)
            {
                try { refineCtx = await RelabelSpeakersFromRecordingAsync(db, topics, refinement, participantCountHint); }
                catch (Exception ex) { _logger.LogWarning(ex, "[Speaker] Offline refinement failed"); }
            }

            // ── Map anonymous speaker labels to real names using screenshot OCR ──
            // Start with real-time mappings, refine with speech-activity-aligned votes
            // (who was actually speaking when the screenshot showed a name), then fill
            // remaining gaps with the classic time-distance vote.
            var speakerMapping = new Dictionary<string, string>(realtimeSpeakerMap);
            if (refineCtx is not null)
                MapSpeakerNamesBySpeechActivity(screenshots, refineCtx, speakerMapping);
            MapSpeakerLabelsToNames(topics, screenshots, speakerMapping);
            if (speakerMapping.Count > 0)
            {
                foreach (var topic in topics)
                {
                    foreach (var tr in topic.Transcripts)
                    {
                        if (tr.Speaker is not null && speakerMapping.TryGetValue(tr.Speaker, out var realName))
                            tr.Speaker = realName;
                    }
                }

                // Batch update in DB
                var allTranscriptIds = topics.SelectMany(t => t.Transcripts).Select(tr => tr.TranscriptId).ToList();
                var dbTranscripts = await db.Transcripts
                    .Where(t => allTranscriptIds.Contains(t.TranscriptId))
                    .ToListAsync();
                foreach (var tr in dbTranscripts)
                {
                    if (tr.Speaker is not null && speakerMapping.TryGetValue(tr.Speaker, out var realName))
                        tr.Speaker = realName;
                }
                await db.SaveChangesAsync();
                _logger.LogInformation("[Session] Speaker mapping applied: {Mapping}",
                    string.Join(", ", speakerMapping.Select(kv => $"{kv.Key}={kv.Value}")));
            }

            // Generate final summary if there's meaningful content
            if (topics.Any(t => t.Transcripts.Count > 0))
            {
                // Preferred path: template-driven structured minutes + quality score
                var ok = await MinutesPipeline.GenerateFinalMinutesAsync(
                    db, session, topics, screenshots, _llm, _logger);
                if (ok)
                    _logger.LogInformation("[Session] Final structured minutes generated");

                if (!ok || string.IsNullOrWhiteSpace(session.Summary))
                {
                    // Legacy fallback: fixed-schema summary prompt
                    var prompt = BuildFinalSummaryPrompt(session, topics, screenshots);
                    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
                    try
                    {
                        var response = await _llm.AnalyzeAsync(prompt, cts.Token);
                        var json = response.Trim();
                        if (json.StartsWith("```")) json = Regex.Replace(json, @"^```\w*\n?|\n?```$", "");
                        using var doc = System.Text.Json.JsonDocument.Parse(json);
                        var root = doc.RootElement;
                        if (root.TryGetProperty("summary", out var summaryEl))
                            session.Summary = summaryEl.GetString();
                        _logger.LogInformation("[Session] Final summary generated (legacy)");
                    }
                    catch (Exception ex)
                    {
                        _logger.LogWarning(ex, "[Session] Final summary generation failed");
                    }
                }

                // Cross-meeting theme classification (best-effort)
                await MinutesPipeline.ClassifyThemeAsync(db, session, topics, _llm, _logger);
            }

            // ── Persist stable voiceprint clusters into the library ──
            // Spec R5: a single stable cluster means "no separation happened" —
            // skip persistence so a solo voice doesn't pollute the library.
            if (_asr is ISpeakerRefinement voiceprints)
            {
                try
                {
                    var stable = voiceprints.GetStableVoiceprintClusters();
                    if (stable.Count >= 2)
                    {
                        await voiceprints.PersistVoiceprintsAsync(cid =>
                        {
                            foreach (var label in new[] { $"发言人{cid}", $"Speaker {cid}" })
                                if (speakerMapping.TryGetValue(label, out var name) && !string.IsNullOrWhiteSpace(name))
                                    return name;
                            return null;
                        });
                        _logger.LogInformation("[Voiceprint] Persisted {Count} stable clusters", stable.Count);
                    }
                }
                catch (Exception ex) { _logger.LogWarning(ex, "[Voiceprint] Persist failed"); }
            }

            session.EndTime = DateTime.Now;
            session.Status  = SessionStatus.Ended;
            await db.SaveChangesAsync();
        }
        catch (Exception ex) { _logger.LogError(ex, "[DB] Failed to end session"); }
    }

    internal static string BuildFinalSummaryPrompt(MeetingSession session, List<Topic> topics,
        List<Screenshot> screenshots, MinutesTemplate? template = null, MeetingFeatures? features = null)
    {
        var sb = new System.Text.StringBuilder();
        var isEn = LocalizationManager.Instance.IsEnglish;

        var duration = session.EndTime.HasValue
            ? (session.EndTime.Value - session.StartTime).ToString(@"hh\:mm")
            : (isEn ? "Unknown" : "未知");

        if (template is not null)
        {
            // Template-driven role (mirrors macOS MinutesPromptBuilder)
            sb.AppendLine(template.Role);
            sb.AppendLine();
        }
        else
        {
            sb.AppendLine(isEn
                ? "You are a meeting-minutes assistant. Generate a structured meeting summary from the complete meeting data below. Write the summary in English."
                : "你是会议纪要助手。请根据以下完整的会议数据生成一份结构化的会议总结。");
            sb.AppendLine();
        }
        sb.AppendLine(isEn
            ? $"Meeting title: {session.Title ?? "Untitled"}"
            : $"会议标题：{session.Title ?? "未命名"}");
        sb.AppendLine(isEn
            ? $"Meeting time: {session.StartTime:yyyy-MM-dd HH:mm} to {session.EndTime?.ToString("yyyy-MM-dd HH:mm") ?? "in progress"}"
            : $"会议时间：{session.StartTime:yyyy-MM-dd HH:mm} 至 {session.EndTime?.ToString("yyyy-MM-dd HH:mm") ?? "进行中"}");
        sb.AppendLine(isEn ? $"Duration: {duration}" : $"会议时长：{duration}");
        if (features is not null)
            sb.AppendLine(isEn
                ? $"Detected type: {TemplateRecommender.MeetingTypeName(features.PredictedType)}"
                : $"识别类型：{TemplateRecommender.MeetingTypeName(features.PredictedType)}");
        sb.AppendLine();

        // Topic overview (screenshot analyses are embedded under the topic they belong to,
        // so the model can correlate "what was on screen" with "what was being discussed")
        sb.AppendLine(isEn
            ? "[Topic Overview] (screen content analysis for each time slot is attached under its topic)"
            : "【议题概览】（各议题下附该时段的屏幕内容分析）");
        for (var i = 0; i < topics.Count; i++)
        {
            var t = topics[i];
            sb.AppendLine(isEn
                ? $"Topic {i + 1}: {t.Title} ({t.StartTime:HH:mm} - {(t.EndTime?.ToString("HH:mm") ?? "now")})"
                : $"议题{i + 1}：{t.Title}（{t.StartTime:HH:mm} - {(t.EndTime?.ToString("HH:mm") ?? "至今")}）");
            if (!string.IsNullOrWhiteSpace(t.Summary))
                sb.AppendLine(isEn ? $"  Summary: {t.Summary}" : $"  摘要：{t.Summary}");

            var topicShots = screenshots
                .Where(s => s.RelatedTopicId == t.TopicId
                    && (s.MeetingRelevance == "high" || s.MeetingRelevance == "medium"
                        || !string.IsNullOrWhiteSpace(s.AISummary)))
                .Take(5)
                .ToList();
            var topicShotChars = 0;
            foreach (var s in topicShots)
            {
                var line = isEn
                    ? $"  Screen[{s.Timestamp:HH:mm:ss}] {s.ContentType ?? "Content"}: {s.AISummary ?? s.OcrText ?? ""}"
                    : $"  屏幕[{s.Timestamp:HH:mm:ss}] {s.ContentType ?? "内容"}：{s.AISummary ?? s.OcrText ?? ""}";
                if (!string.IsNullOrWhiteSpace(s.KeyNumbers) && s.KeyNumbers != "[]")
                    line += isEn ? $" (Key data: {s.KeyNumbers})" : $"（关键数据：{s.KeyNumbers}）";
                if (!string.IsNullOrWhiteSpace(s.KeyDates) && s.KeyDates != "[]")
                    line += isEn ? $" (Key dates: {s.KeyDates})" : $"（关键日期：{s.KeyDates}）";
                if (!string.IsNullOrWhiteSpace(s.SlideDecisions) && s.SlideDecisions != "[]")
                    line += isEn ? $" (Decisions on slide: {s.SlideDecisions})" : $"（页面决策：{s.SlideDecisions}）";
                if (!string.IsNullOrWhiteSpace(s.SlideActionItems) && s.SlideActionItems != "[]")
                    line += isEn ? $" (Action items on slide: {s.SlideActionItems})" : $"（页面行动项：{s.SlideActionItems}）";
                if (!string.IsNullOrWhiteSpace(s.ChartInsight))
                    line += isEn ? $" (Chart insight: {s.ChartInsight})" : $"（图表洞察：{s.ChartInsight}）";
                if (topicShotChars + line.Length > 800) break;
                sb.AppendLine(line);
                topicShotChars += line.Length;
            }
        }
        sb.AppendLine();

        // All decisions
        var allDecisions = topics.SelectMany(t => t.Decisions).ToList();
        if (allDecisions.Count > 0)
        {
            sb.AppendLine(isEn ? "[All decisions]" : "【所有决策】");
            foreach (var d in allDecisions)
                sb.AppendLine($"- {d.DecisionText}");
            sb.AppendLine();
        }

        // All action items
        var allActions = topics.SelectMany(t => t.ActionItems).ToList();
        if (allActions.Count > 0)
        {
            sb.AppendLine(isEn ? "[All action items]" : "【所有行动项】");
            foreach (var a in allActions)
                sb.AppendLine($"- {a.AssignedTo}: {a.Task}" + (a.Deadline is not null ? $" ({a.Deadline})" : ""));
            sb.AppendLine();
        }

        // Screenshots not attributable to any topic (only high/medium relevance, tight cap)
        var topicIds = topics.Select(t => t.TopicId).ToHashSet();
        var orphanShots = screenshots
            .Where(s => (s.MeetingRelevance == "high" || s.MeetingRelevance == "medium")
                && (s.RelatedTopicId is null || !topicIds.Contains(s.RelatedTopicId.Value)))
            .ToList();
        if (orphanShots.Count > 0)
        {
            sb.AppendLine(isEn
                ? "[Other screen content] (key screenshots not attributable to any topic)"
                : "【其他屏幕内容】（未归属议题的关键截图）");
            var charCount = 0;
            foreach (var s in orphanShots)
            {
                var line = isEn
                    ? $"[{s.Timestamp:HH:mm:ss}] Type: {s.ContentType ?? "Unknown"} | Content: {s.AISummary ?? ""}"
                    : $"[{s.Timestamp:HH:mm:ss}] 类型：{s.ContentType ?? "未知"} | 内容：{s.AISummary ?? ""}";
                if (!string.IsNullOrWhiteSpace(s.OcrText))
                    line += isEn ? $" | Key text: {s.OcrText}" : $" | 关键文字：{s.OcrText}";
                if (!string.IsNullOrWhiteSpace(s.KeyNumbers))
                    line += isEn ? $" | Key data: {s.KeyNumbers}" : $" | 关键数据：{s.KeyNumbers}";
                if (charCount + line.Length > 1500) break;
                sb.AppendLine(line);
                charCount += line.Length + 1;
            }
            sb.AppendLine();
        }

        sb.AppendLine(isEn
            ? "Note: the transcript is the verbal discussion; the screen content analysis is what participants saw at the time (slides/charts/documents etc.). " +
              "Combine the two — when data or conclusions shown on screen were discussed, reflect their specific content in the summary."
            : "请注意：转录文本是口头讨论，屏幕内容分析是与会者当时看到的信息（PPT/图表/文档等）。" +
              "请将两者结合——屏幕上展示的数据、结论若被讨论到，应在总结中体现其具体内容。");
        sb.AppendLine();

        if (template is not null)
        {
            if (!string.IsNullOrEmpty(template.ExtraGuidance))
            {
                sb.AppendLine(isEn ? "[Template Guidance]" : "【模板要求】");
                sb.AppendLine(template.ExtraGuidance);
                sb.AppendLine();
            }
            sb.Append(BuildTemplateOutputSchema(template, isEn));
            return sb.ToString();
        }

        if (isEn)
        {
            sb.AppendLine("Generate a complete meeting summary as JSON:");
            sb.AppendLine("{");
            sb.AppendLine("  \"summary\": \"An overall 3-5 sentence overview covering the meeting's goals, discussion points, and core outcomes\",");
            sb.AppendLine("  \"key_highlights\": [\"highlight1\", \"highlight2\", \"highlight3\"],");
            sb.AppendLine("  \"next_steps\": [\"suggested next step 1\", \"suggested next step 2\"]");
            sb.AppendLine("}");
            sb.AppendLine("Return JSON only, no Markdown.");
        }
        else
        {
            sb.AppendLine("请生成一份完整的会议总结，用JSON格式返回：");
            sb.AppendLine("{");
            sb.AppendLine("  \"summary\": \"3-5句话的整体会议概述，涵盖会议目标、讨论要点、核心成果\",");
            sb.AppendLine("  \"key_highlights\": [\"要点1\", \"要点2\", \"要点3\"],");
            sb.AppendLine("  \"next_steps\": [\"后续行动建议1\", \"后续行动建议2\"]");
            sb.AppendLine("}");
            sb.AppendLine("只返回JSON，不要Markdown标记。");
        }

        return sb.ToString();
    }

    /// <summary>Template-driven JSON output schema — mirrors macOS MinutesPromptBuilder.outputSchema.</summary>
    private static string BuildTemplateOutputSchema(MinutesTemplate template, bool en)
    {
        var fields = new List<string>
        {
            en
                ? "\"summary\": \"3-5 sentence executive summary: goals, key discussion, outcomes\""
                : "\"summary\": \"3-5句话的整体概述：会议目标、讨论要点、核心成果\""
        };
        foreach (var section in template.Sections)
        {
            switch (section)
            {
                case MinutesSection.CoreSummary: break;
                case MinutesSection.Decisions:
                    fields.Add(en
                        ? "\"decisions\": [{\"text\": \"conclusion statement\", \"rationale\": \"why\", \"source_speaker\": \"who said it or null\"}]"
                        : "\"decisions\": [{\"text\": \"结论性语句\", \"rationale\": \"决策依据\", \"source_speaker\": \"提出人，未知则null\"}]");
                    break;
                case MinutesSection.ActionItems:
                    fields.Add(en
                        ? "\"action_items\": [{\"task\": \"specific task\", \"owner\": \"owner\", \"deadline\": \"YYYY-MM-DD or null\", \"priority\": \"high/medium/low\", \"source_speaker\": \"who proposed or null\"}]"
                        : "\"action_items\": [{\"task\": \"具体任务\", \"owner\": \"负责人\", \"deadline\": \"YYYY-MM-DD 或 null\", \"priority\": \"high/medium/low\", \"source_speaker\": \"提出人，未知则null\"}]");
                    break;
                case MinutesSection.Risks:
                    fields.Add(en
                        ? "\"risks\": [\"risk or unconfirmed item with impact\"]"
                        : "\"risks\": [\"风险或待确认事项，含影响描述\"]");
                    break;
                case MinutesSection.OpenQuestions:
                    fields.Add(en
                        ? "\"open_questions\": [\"unresolved question\"]"
                        : "\"open_questions\": [\"未解决的问题\"]");
                    break;
                case MinutesSection.TopicDetails:
                    fields.Add(en
                        ? "\"topic_details\": [{\"title\": \"topic name\", \"points\": [\"3-5 discussion points\"]}]"
                        : "\"topic_details\": [{\"title\": \"议题名\", \"points\": [\"3-5条讨论要点\"]}]");
                    break;
                case MinutesSection.Highlights:
                    fields.Add(en
                        ? "\"key_highlights\": [\"highlight 1\", \"highlight 2\"]"
                        : "\"key_highlights\": [\"要点1\", \"要点2\"]");
                    break;
                case MinutesSection.NextSteps:
                    fields.Add(en
                        ? "\"next_steps\": [\"suggested follow-up\"]"
                        : "\"next_steps\": [\"后续行动建议\"]");
                    break;
            }
        }

        var sb = new System.Text.StringBuilder();
        sb.AppendLine(en
            ? "[Output Requirements]\nReturn JSON only (no Markdown fences). Cross-check decisions/action items with both the transcript-derived lists and the screen content above; merge duplicates and prefer the most precise wording. Use empty arrays when a section has no content."
            : "【输出要求】\n只返回JSON（不要Markdown代码块）。决策与行动项需与上方转写提取结果和屏幕内容交叉核对，合并重复项，采用最准确的表述。无内容的章节返回空数组。");
        sb.AppendLine("{");
        sb.AppendLine("  " + string.Join(",\n  ", fields));
        sb.AppendLine("}");
        return sb.ToString();
    }

    /// <summary>Result of the offline diarization pass, used for name-vote alignment.</summary>
    private sealed record SpeakerRefinementContext(
        DateTime StartedAt, List<DiarizedSegment> Segments, Dictionary<int, string> ClusterToLabel);

    /// <summary>Anonymous speaker labels: "发言人N" (Chinese ASR) or "Speaker N" (English ASR).
    /// Old Chinese DB records keep the 发言人 prefix, so both must be recognized.</summary>
    private static bool IsAnonymousSpeakerLabel(string? label)
        => label is not null
           && (label.StartsWith("发言人", StringComparison.Ordinal)
               || label.StartsWith("Speaker", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Re-labels "发言人N"/"Speaker N" transcripts using an offline diarization pass over the meeting
    /// recording. Offline cluster IDs are mapped back onto the existing online labels by
    /// majority vote, so downstream OCR name mapping and manual renames keep working.
    /// Returns the alignment context for speech-activity-based name mapping, or null.
    /// </summary>
    private async Task<SpeakerRefinementContext?> RelabelSpeakersFromRecordingAsync(
        AppDbContext db, List<Topic> topics, ISpeakerRefinement refinement, int? participantCountHint)
    {
        var startedAt = refinement.RecordingStartedAt;
        if (startedAt is null || refinement.LastRecordingPath is null) return null;

        var segments = await refinement.DiarizeLastRecordingAsync(participantCountHint);
        if (segments.Count == 0) return null;

        // Endpoint commits fire ~1.2s (Rule2 trailing silence) after the utterance ends.
        const double commitLagSec  = 1.2;
        const double maxSnapSec    = 1.5;

        var labeled = topics.SelectMany(t => t.Transcripts)
            .Where(tr => tr.Speaker is not null && IsAnonymousSpeakerLabel(tr.Speaker))
            .ToList();
        if (labeled.Count == 0) return null;

        // 1. Assign each transcript to an offline cluster by timestamp alignment.
        var assignments = new List<(Transcript Tr, int Cluster)>();
        foreach (var tr in labeled)
        {
            var tSec = (tr.Timestamp - startedAt.Value).TotalSeconds - commitLagSec;

            var seg = segments.FirstOrDefault(s => tSec >= s.StartSec && tSec <= s.EndSec);
            if (seg is null)
            {
                seg = segments
                    .Select(s => (Seg: s, Dist: Math.Max(Math.Max(s.StartSec - tSec, tSec - s.EndSec), 0)))
                    .Where(x => x.Dist <= maxSnapSec)
                    .OrderBy(x => x.Dist)
                    .FirstOrDefault().Seg;
            }

            if (seg is not null)
                assignments.Add((tr, seg.SpeakerIndex));
        }
        if (assignments.Count == 0) return null;

        // 2. Map each offline cluster to the majority online label (keeps label identity).
        var clusterToLabel = assignments
            .GroupBy(a => a.Cluster)
            .ToDictionary(
                g => g.Key,
                g => g.GroupBy(a => a.Tr.Speaker!)
                      .OrderByDescending(x => x.Count())
                      .First().Key);

        // 3. Re-label tracked entities and persist.
        var changed = 0;
        foreach (var (tr, cluster) in assignments)
        {
            var newLabel = clusterToLabel[cluster];
            if (tr.Speaker != newLabel)
            {
                tr.Speaker = newLabel;
                changed++;
            }
        }
        if (changed > 0)
            await db.SaveChangesAsync();

        _logger.LogInformation(
            "[Speaker] Offline refinement re-labeled {Changed}/{Total} utterances",
            changed, assignments.Count);

        return new SpeakerRefinementContext(startedAt.Value, segments, clusterToLabel);
    }

    /// <summary>
    /// Maps speaker labels to real names using offline diarization segments: a screenshot
    /// showing "张三 正在发言" at time T votes for the label whose speech segment covers T —
    /// the person who was actually speaking then, not merely the nearest screenshot in time.
    /// </summary>
    private static void MapSpeakerNamesBySpeechActivity(
        List<Screenshot> screenshots, SpeakerRefinementContext ctx,
        Dictionary<string, string> mapping)
    {
        var nameShots = screenshots
            .Where(s => !string.IsNullOrWhiteSpace(s.ActiveSpeakerName))
            .ToList();
        if (nameShots.Count == 0 || ctx.Segments.Count == 0) return;

        const double toleranceSec = 0.75;
        var votes = new Dictionary<string, Dictionary<string, double>>();

        foreach (var shot in nameShots)
        {
            var tSec = (shot.Timestamp - ctx.StartedAt).TotalSeconds;
            var seg = ctx.Segments.FirstOrDefault(
                s => tSec >= s.StartSec - toleranceSec && tSec <= s.EndSec + toleranceSec);
            if (seg is null) continue;
            if (!ctx.ClusterToLabel.TryGetValue(seg.SpeakerIndex, out var label)) continue;
            if (mapping.ContainsKey(label)) continue;

            if (!votes.TryGetValue(label, out var v))
                v = votes[label] = new Dictionary<string, double>();
            v[shot.ActiveSpeakerName!] = v.GetValueOrDefault(shot.ActiveSpeakerName!) + 1;
        }

        foreach (var (label, v) in votes)
        {
            var ranked = v.OrderByDescending(kv => kv.Value).Take(2).ToList();
            var winner = ranked[0];
            // Same clear-margin rule as the classic vote: unanimous or ≥1.5× runner-up
            var clear = ranked.Count == 1 || winner.Value >= ranked[1].Value * 1.5;
            if (clear)
                mapping[label] = winner.Key;
        }
    }

    // ── Real-time speaker name helpers ───────────────────────────────────

    /// <summary>Returns the speaker label active at time <paramref name="t"/>.</summary>
    private string? LabelAtTime(DateTime t)
    {
        lock (_speakerTimeline)
        {
            for (var i = _speakerTimeline.Count - 1; i >= 0; i--)
                if (_speakerTimeline[i].Time <= t)
                    return _speakerTimeline[i].Label;
        }
        return null;
    }

    /// <summary>
    /// Accumulates a label→name vote. First-seen labels (screenshot was triggered for them)
    /// map on the first vote; others need 2 agreeing votes to guard against OCR errors.
    /// Committed mappings are backfilled into already-saved transcripts immediately.
    /// </summary>
    private void AddSpeakerNameVote(string label, string name)
    {
        string winner;
        // Single lock guards the whole vote → commit pipeline: _speakerNameMap check,
        // vote accumulation and _pendingSpeakerLabels must not interleave with
        // OnTranscriptReceived's new-speaker check or another vote on another thread.
        lock (_participantLock)
        {
            if (_speakerNameMap.TryGetValue(label, out var existing) && existing == name)
                return;
            if (_speakerNameMap.ContainsKey(label))
                return;

            if (!_labelNameVotes.TryGetValue(label, out var votes))
                votes = _labelNameVotes[label] = new Dictionary<string, int>();
            votes[name] = votes.GetValueOrDefault(name) + 1;

            var top = votes.OrderByDescending(kv => kv.Value).First();
            var confident = top.Value >= 2 || _pendingSpeakerLabels.Contains(label);
            if (!confident)
                return;

            winner = top.Key;
            _speakerNameMap[label] = winner;
            _pendingSpeakerLabels.Remove(label);
        }

        _logger.LogInformation("[Speaker] Mapped {Label} → {Name}", label, winner);
        _ = Task.Run(() => BackfillSpeakerNameAsync(label, winner));
    }

    /// <summary>Replaces an anonymous label with the real name on all transcripts
    /// already saved in the current session.</summary>
    private async Task BackfillSpeakerNameAsync(string label, string name)
    {
        if (!_currentSessionId.HasValue) return;
        try
        {
            var sessionId = _currentSessionId.Value;
            using var db = _dbFactory.CreateDbContext();
            var rows = await db.Topics
                .Where(t => t.SessionId == sessionId)
                .SelectMany(t => t.Transcripts)
                .Where(tr => tr.Speaker == label)
                .ToListAsync();
            foreach (var r in rows) r.Speaker = name;
            if (rows.Count > 0)
                await db.SaveChangesAsync();
        }
        catch (Exception ex) { _logger.LogWarning(ex, "[Speaker] Backfill failed"); }
    }

    /// <summary>Captures an explicit "N 人参会" participant-count signal from OCR text.</summary>
    private void TryUpdateParticipantCountHint(string? ocrText)
    {
        if (string.IsNullOrWhiteSpace(ocrText)) return;
        var m = System.Text.RegularExpressions.Regex.Match(ocrText,
            @"(\d{1,2})\s*人(?:参会|与会|在会)|参会人数[:：]?\s*(\d{1,2})|(\d{1,2})\s*位参会");
        if (!m.Success) return;
        var g = m.Groups;
        var raw = g[1].Success ? g[1].Value : g[2].Success ? g[2].Value : g[3].Value;
        if (int.TryParse(raw, out var n) && n is >= 2 and <= 20)
            lock (_participantLock)
                _participantCountHint = Math.Max(_participantCountHint ?? 0, n);
    }

    /// <summary>
    /// Maps anonymous speaker labels (发言人1, 发言人2, ...) to real names by
    /// correlating every labeled transcript timestamp with nearby screenshot
    /// ActiveSpeakerName (OCR) using a distance-weighted majority vote.
    /// A label is only mapped when the winning name has a clear margin;
    /// ambiguous labels are left unmapped for manual correction in History.
    /// Existing mappings in <paramref name="mapping"/> are preserved.
    /// </summary>
    private static void MapSpeakerLabelsToNames(
        List<Topic> topics, List<Screenshot> screenshots,
        Dictionary<string, string> mapping)
    {
        // Collect all labeled transcripts with timestamps, skip already-mapped labels
        var labelTimestamps = topics
            .SelectMany(t => t.Transcripts)
            .Where(tr => tr.Speaker is not null
                && IsAnonymousSpeakerLabel(tr.Speaker)
                && !mapping.ContainsKey(tr.Speaker))
            .Select(tr => (Label: tr.Speaker!, tr.Timestamp))
            .ToList();

        if (labelTimestamps.Count == 0) return;

        // Screenshots with known speaker names
        var nameShots = screenshots
            .Where(s => !string.IsNullOrWhiteSpace(s.ActiveSpeakerName))
            .OrderBy(s => s.Timestamp)
            .ToList();

        if (nameShots.Count == 0) return;

        // For each unique label, accumulate weighted votes over ALL occurrences
        foreach (var labelGroup in labelTimestamps.GroupBy(lt => lt.Label))
        {
            var label = labelGroup.Key;
            var votes = new Dictionary<string, double>();

            foreach (var ts in labelGroup.Select(lt => lt.Timestamp))
            {
                // Find the screenshot closest in time to this occurrence (±60s window)
                string? nearestName = null;
                double bestDistance = 60;
                foreach (var s in nameShots)
                {
                    var dist = Math.Abs((s.Timestamp - ts).TotalSeconds);
                    if (dist < bestDistance)
                    {
                        bestDistance = dist;
                        nearestName = s.ActiveSpeakerName;
                    }
                }

                if (nearestName is not null)
                    // Closer screenshots vote heavier (weight 1.0 at 0s → ~0.14 at 60s)
                    votes[nearestName] = votes.GetValueOrDefault(nearestName)
                        + 1.0 / (1.0 + bestDistance / 10.0);
            }

            if (votes.Count == 0) continue;

            var ranked = votes.OrderByDescending(kv => kv.Value).Take(2).ToList();
            var winner = ranked[0];
            // Require a clear winner: unanimous, or at least 1.5× the runner-up
            var clear = ranked.Count == 1 || winner.Value >= ranked[1].Value * 1.5;
            if (clear)
                mapping[label] = winner.Key;
        }
    }
}
