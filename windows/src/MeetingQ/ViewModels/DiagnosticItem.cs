using CommunityToolkit.Mvvm.ComponentModel;

namespace MeetingQ.ViewModels;

public enum DiagState { Pending, Running, OK, Warning, Error }

/// <summary>
/// One row in the startup diagnostics panel (e.g., "音频设备", "ASR连接").
/// All property mutations marshal to the UI thread internally.
/// </summary>
public partial class DiagnosticItem : ObservableObject
{
    public string Name { get; init; } = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Icon))]
    [NotifyPropertyChangedFor(nameof(IconColor))]
    [NotifyPropertyChangedFor(nameof(DetailColor))]
    private DiagState _state = DiagState.Pending;

    [ObservableProperty] private string _detail = string.Empty;

    public string Icon => State switch
    {
        DiagState.Pending  => "○",
        DiagState.Running  => "⟳",
        DiagState.OK       => "✓",
        DiagState.Warning  => "⚠",
        DiagState.Error    => "✕",
        _                  => "○"
    };

    public string IconColor => State switch
    {
        DiagState.OK      => "#4ADE80",
        DiagState.Warning => "#FBBF24",
        DiagState.Error   => "#FF6B6B",
        DiagState.Running => "#60A5FA",
        _                 => "#555555"
    };

    public string DetailColor => State switch
    {
        DiagState.Error   => "#EF4444",
        DiagState.Warning => "#D97706",
        DiagState.OK      => "#16A34A",
        _                 => "#888888"
    };

    // ── Thread-safe setters ───────────────────────────────────────────────

    public void SetPending()             => Dispatch(() => { State = DiagState.Pending; Detail = string.Empty; });
    public void SetRunning(string detail = "检测中...") => Dispatch(() => { State = DiagState.Running; Detail = detail; });
    public void SetOk(string detail)     => Dispatch(() => { State = DiagState.OK;      Detail = detail; });
    public void SetWarning(string detail) => Dispatch(() => { State = DiagState.Warning; Detail = detail; });
    public void SetError(string detail)   => Dispatch(() => { State = DiagState.Error;   Detail = detail; });

    private static void Dispatch(Action action)
    {
        var app = System.Windows.Application.Current;
        if (app is null) return;
        if (app.Dispatcher.CheckAccess())
            action();
        else
            app.Dispatcher.BeginInvoke(action);
    }
}
