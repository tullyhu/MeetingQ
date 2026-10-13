using System.Diagnostics;
using System.Runtime.InteropServices;
using MeetingQ.Infrastructure;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using Timer = System.Threading.Timer;

namespace MeetingQ.Services;

/// <summary>
/// Automatic meeting detection for the passive-listening scenario (Windows port
/// of macOS MeetingWatcherService; see docs/meeting_auto_detect_spec.md).
///
/// Evidence model:
/// - Candidate: a known meeting process (data-driven profile table) with a window.
/// - Start evidence: the process holds an ACTIVE audio session on the render
///   endpoint (output). Meeting apps hold output for the whole call — works for
///   muted, camera-off listeners. An active capture (input) session is only a
///   start accelerator, never end evidence.
/// - Hard end: the meeting process exits or its main window is destroyed
///   (minimize keeps the HWND — does NOT count).
/// - Soft end: output session inactive for a grace period → balloon prompt,
///   never auto-stop.
///
/// Audio session enumeration uses NAudio's AudioSessionManager over the default
/// render/capture endpoints — the Windows analogue of CoreAudio process objects.
/// </summary>
public sealed class MeetingWatcherService : IDisposable
{
    public enum Mode { Off, Prompt, Auto }

    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);
    private const int ConfirmHitsRequired = 2;
    private static readonly TimeSpan SoftEndGrace = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan CooldownAfterStop = TimeSpan.FromMinutes(10);

    /// <summary>Data-driven platform table; extend by adding rows.</summary>
    private sealed record Profile(string DisplayName, string[] ProcessNames, string[] TitlePatterns);

    private static readonly Profile[] Profiles =
    {
        new("Zoom",            new[] { "Zoom" },                      new[] { "Zoom" }),
        new("腾讯会议",        new[] { "wemeetapp", "WeMeetApp" },    new[] { "腾讯会议" }),
        new("飞书",            new[] { "Feishu", "Lark" },            new[] { "飞书", "Lark" }),
        new("钉钉",            new[] { "DingTalk" },                  new[] { "钉钉" }),
        new("Microsoft Teams", new[] { "ms-teams", "Teams" },         new[] { "Microsoft Teams", "Teams" }),
        new("Webex",           new[] { "webexmta", "CiscoWebex" },    new[] { "Webex" }),
    };

    // Browser titles matched against meeting page patterns (weak evidence; the
    // audio-output requirement stays mandatory). Browser URL evidence via UIA
    // address bar is a possible refinement — deliberately not v1.
    private static readonly (string Process, string Pattern)[] BrowserPatterns =
    {
        ("chrome",  "meet.google.com"), ("chrome",  "Zoom"),
        ("msedge",  "meet.google.com"), ("msedge",  "Microsoft Teams"),
        ("firefox", "meet.google.com"),
    };

    private enum State { Idle, Confirming, InMeeting, Cooldown }

    private State _state = State.Idle;
    private int _confirmPid;
    private string _confirmTitle = "";
    private string _confirmPlatform = "";
    private int _confirmHits;
    private bool _confirmAccelerated;
    private int _meetingPid;
    private IntPtr _meetingWindow;
    private DateTime _cooldownUntil;
    private DateTime? _outputMissingSince;
    private bool _softEndPrompted;

    private readonly Timer _timer;
    private bool _isMonitoring;
    private bool _disposed;

    /// <summary>Wired by App: show a balloon; clicking it invokes <see cref="ConfirmPendingPrompt"/>.</summary>
    public Action<string, string>? ShowPrompt { get; set; }

    /// <summary>Auto-start requested (auto mode, or user clicked the start balloon).</summary>
    public event Action? StartRequested;
    /// <summary>Stop requested (hard end, or user clicked the end balloon).</summary>
    public event Action? StopRequested;

    private Action? _pendingPromptAction;

    public Mode CurrentMode
    {
        get => SecureStorage.Load(SecureStorageKeys.MeetingAutoDetectMode) switch
        {
            "off"  => Mode.Off,
            "auto" => Mode.Auto,
            _      => Mode.Prompt,
        };
    }

    public MeetingWatcherService()
    {
        _timer = new Timer(_ => Poll(), null, PollInterval, PollInterval);
    }

    /// <summary>FloatingWindowViewModel reports monitoring transitions (manual stop → cooldown).</summary>
    public void NotifyMonitoringChanged(bool monitoring)
    {
        if (_isMonitoring && !monitoring && _state == State.InMeeting)
        {
            _state = State.Cooldown;
            _cooldownUntil = DateTime.Now + CooldownAfterStop;
        }
        _isMonitoring = monitoring;
        if (!monitoring)
        {
            _outputMissingSince = null;
            _softEndPrompted = false;
        }
    }

    /// <summary>Invoked when the user clicks the prompt balloon.</summary>
    public void ConfirmPendingPrompt()
    {
        var action = Interlocked.Exchange(ref _pendingPromptAction, null);
        action?.Invoke();
    }

    // ── Poll ─────────────────────────────────────────────────────────────

    private void Poll()
    {
        if (_disposed) return;
        try
        {
            if (_isMonitoring) PollWhileMonitoring();
            else               PollWhileIdle();
        }
        catch (Exception ex)
        {
            AppLog.Warn<MeetingWatcherService>($"[Watcher] Poll failed: {ex.Message}");
        }
    }

    private void PollWhileMonitoring()
    {
        if (_state != State.InMeeting) return;

        // Hard end: meeting process gone or its window destroyed.
        var processAlive = ProcessExists(_meetingPid);
        var windowAlive  = _meetingWindow != IntPtr.Zero && IsWindow(_meetingWindow);
        if (!processAlive || (!windowAlive && !HasAnyWindow(_meetingPid)))
        {
            _state = State.Cooldown;
            _cooldownUntil = DateTime.Now + CooldownAfterStop;
            AppLog.Info<MeetingWatcherService>("[Watcher] Meeting window destroyed — hard end");
            RaiseOnUi(StopRequested);
            return;
        }

        // Soft end: output session inactive for the grace period.
        if (HasActiveSession(_meetingPid, DataFlow.Render))
        {
            _outputMissingSince = null;
            return;
        }
        _outputMissingSince ??= DateTime.Now;
        if (!_softEndPrompted && DateTime.Now - _outputMissingSince >= SoftEndGrace)
        {
            _softEndPrompted = true;
            Prompt(
                LocalizationManager.Get("WatcherEndTitle"),
                LocalizationManager.Get("WatcherEndBody"),
                () => RaiseOnUi(StopRequested));
        }
    }

    private void PollWhileIdle()
    {
        if (CurrentMode == Mode.Off) { _state = State.Idle; return; }
        if (_state == State.Cooldown)
        {
            if (DateTime.Now < _cooldownUntil) return;
            _state = State.Idle;
        }

        var candidate = DetectCandidate();
        if (candidate is null)
        {
            _state = State.Idle;
            return;
        }

        var (pid, title, platform, window, accelerated) = candidate.Value;
        if (_state == State.Confirming && _confirmPid == pid)
        {
            if (_confirmAccelerated || _confirmHits + 1 >= ConfirmHitsRequired)
            {
                _state = State.InMeeting;
                _meetingPid = pid;
                _meetingWindow = window;
                TriggerStart(title, platform);
            }
            else
            {
                _confirmHits++;
            }
        }
        else
        {
            _state = State.Confirming;
            _confirmPid = pid;
            _confirmTitle = title;
            _confirmPlatform = platform;
            _confirmHits = 1;
            _confirmAccelerated = accelerated;
        }
    }

    private void TriggerStart(string title, string platform)
    {
        AppLog.Info<MeetingWatcherService>($"[Watcher] Meeting detected: {platform} / {title}");
        if (CurrentMode == Mode.Auto)
        {
            RaiseOnUi(StartRequested);
        }
        else
        {
            Prompt(
                LocalizationManager.Get("WatcherStartTitle"),
                string.Format(LocalizationManager.Get("WatcherStartBody"), platform, title),
                () => RaiseOnUi(StartRequested));
        }
    }

    private void Prompt(string title, string body, Action onConfirm)
    {
        _pendingPromptAction = onConfirm;
        ShowPrompt?.Invoke(title, body);
    }

    private static void RaiseOnUi(Action? handler)
    {
        if (handler is null) return;
        System.Windows.Application.Current?.Dispatcher.Invoke(handler);
    }

    // ── Detection ────────────────────────────────────────────────────────

    private (int Pid, string Title, string Platform, IntPtr Window, bool Accelerated)? DetectCandidate()
    {
        // PIDs with an ACTIVE session on the render endpoint = playing sound now.
        var outputPids = ActiveSessionPids(DataFlow.Render);
        if (outputPids.Count == 0) return null;
        var inputPids = ActiveSessionPids(DataFlow.Capture);

        foreach (var pid in outputPids)
        {
            Process? proc;
            try { proc = Process.GetProcessById(pid); }
            catch { continue; }
            using (proc)
            {
                string name;
                try { name = proc.ProcessName; }
                catch { continue; }

                var profile = Profiles.FirstOrDefault(p =>
                    p.ProcessNames.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase)));
                string? title = null;
                string? platform = null;

                if (profile is not null)
                {
                    title = SafeMainWindowTitle(proc) ?? profile.DisplayName;
                    platform = profile.DisplayName;
                }
                else
                {
                    // Browser weak-evidence path: title must match a meeting pattern.
                    var t = SafeMainWindowTitle(proc);
                    var browser = BrowserPatterns.FirstOrDefault(b =>
                        string.Equals(b.Process, name, StringComparison.OrdinalIgnoreCase)
                        && t is not null && t.Contains(b.Pattern, StringComparison.OrdinalIgnoreCase));
                    if (t is null || browser == default) continue;
                    title = t;
                    platform = browser.Pattern;
                }

                var accelerated = inputPids.Contains(pid);
                return (pid, title!, platform!, proc.MainWindowHandle, accelerated);
            }
        }
        return null;
    }

    // ── Windows / session helpers ────────────────────────────────────────

    private static HashSet<int> ActiveSessionPids(DataFlow flow)
    {
        var result = new HashSet<int>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(flow, Role.Multimedia);
            var sessions = device.AudioSessionManager.Sessions;
            for (var i = 0; i < sessions.Count; i++)
            {
                using var session = sessions[i];
                if (session.State == AudioSessionState.AudioSessionStateActive)
                    result.Add((int)session.GetProcessID);
            }
        }
        catch (Exception ex)
        {
            AppLog.Warn<MeetingWatcherService>($"[Watcher] Session enumeration failed: {ex.Message}");
        }
        return result;
    }

    private static bool HasActiveSession(int pid, DataFlow flow) =>
        ActiveSessionPids(flow).Contains(pid);

    private static bool ProcessExists(int pid)
    {
        try { using var p = Process.GetProcessById(pid); return !p.HasExited; }
        catch { return false; }
    }

    private static string? SafeMainWindowTitle(Process p)
    {
        try { var t = p.MainWindowTitle; return string.IsNullOrWhiteSpace(t) ? null : t; }
        catch { return null; }
    }

    private static bool HasAnyWindow(int pid)
    {
        var found = false;
        EnumWindows((hWnd, _) =>
        {
            GetWindowThreadProcessId(hWnd, out var wpid);
            if (wpid == pid && IsWindowVisible(hWnd)) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int processId);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _timer.Dispose();
    }
}
