using System.IO;
using System.Text;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Static file logger — writes directly to a per-session log file, completely
/// independent of the .NET logging framework so no filter rule or appsettings.json
/// can silently suppress our diagnostic output.
///
/// Call <see cref="Initialize"/> once at application startup (before building the host).
/// Call <see cref="Close"/> in OnExit.
/// </summary>
public static class AppLog
{
    private static StreamWriter? _writer;
    private static readonly object _lock = new();

    public static string LogDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                     "MeetingQ", "Logs");

    public static void Initialize()
    {
        Directory.CreateDirectory(LogDirectory);
        var path = Path.Combine(LogDirectory, $"meetingq-{DateTime.Now:yyyy-MM-dd-HHmmss}.log");
        _writer = new StreamWriter(path, append: false, Encoding.UTF8) { AutoFlush = true };
        Write("INFO", "App", $"=== MeetingQ started — log: {path} ===");
        CleanupOld();
    }

    // ── Category-string overloads ──────────────────────────────────────────

    public static void Debug(string cat, string msg)                      => Write("DBUG", cat, msg);
    public static void Info (string cat, string msg)                      => Write("INFO", cat, msg);
    public static void Warn (string cat, string msg)                      => Write("WARN", cat, msg);
    public static void Error(string cat, string msg, Exception? ex = null) => Write("ERRO", cat, msg, ex);

    // ── Generic overloads (derive category from type name) ─────────────────

    public static void Debug<T>(string msg)                       => Write("DBUG", Short<T>(), msg);
    public static void Info <T>(string msg)                       => Write("INFO", Short<T>(), msg);
    public static void Warn <T>(string msg)                       => Write("WARN", Short<T>(), msg);
    public static void Error<T>(string msg, Exception? ex = null) => Write("ERRO", Short<T>(), msg, ex);

    // ── Shutdown ───────────────────────────────────────────────────────────

    public static void Close()
    {
        lock (_lock) { _writer?.Dispose(); _writer = null; }
    }

    // ── Internals ──────────────────────────────────────────────────────────

    private static string Short<T>() => typeof(T).Name;

    private static void Write(string level, string cat, string msg, Exception? ex = null)
    {
        lock (_lock)
        {
            try
            {
                var line = $"[{DateTime.Now:HH:mm:ss.fff}] [{level}] [{cat}] {msg}";
                if (_writer is not null)
                {
                    _writer.WriteLine(line);
                    if (ex is not null)
                        _writer.WriteLine($"  {ex}");
                }
                else
                {
                    // After Close() (or before Initialize()) — don't silently drop.
                    System.Diagnostics.Debug.WriteLine(line);
                    if (ex is not null)
                        System.Diagnostics.Debug.WriteLine($"  {ex}");
                }
            }
            catch { /* never throw from logger */ }
        }
    }

    private static void CleanupOld()
    {
        try
        {
            foreach (var f in Directory.GetFiles(LogDirectory, "meetingq-*.log")
                                       .OrderByDescending(x => x).Skip(10))
                File.Delete(f);
        }
        catch { }
    }
}
