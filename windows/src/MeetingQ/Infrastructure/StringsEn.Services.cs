namespace MeetingQ.Infrastructure;

/// <summary>
/// English strings for Services/*, App.xaml.cs (MessageBoxes + tray menu).
/// Mirrors every key in StringsZh.Services.cs.
/// </summary>
internal static partial class StringsEn
{
    private static IEnumerable<KeyValuePair<string, string>> ServiceEntries => new Dictionary<string, string>
    {
        // ── System tray ─────────────────────────────────────────────────
        ["TrayTooltip"]  = "MeetingQ — double-click to show the main window",
        ["TrayShowMain"] = "Show Main Window",
        ["TrayHistory"]  = "Meeting History…",
        ["TraySettings"] = "Settings…",
        ["TrayOpenLogs"] = "Open Log Folder",
        ["TrayExit"]     = "Exit MeetingQ",

        // ── App startup / crash dialogs ─────────────────────────────────
        ["AppStartupErrorTitle"]   = "MeetingQ Startup Error",
        ["AppRuntimeErrorTitle"]   = "MeetingQ Runtime Error",
        ["AppDbErrorTitle"]        = "MeetingQ Database Error",
        ["AppDbMigrationFailedBody"] = "Database migration failed: {0}\n\nYour meeting data may be corrupted. Database backup file:\n{1}",
        ["AppDbBackupUnavailable"] = "(backup failed — no backup available)",
        ["AppLaunchFailedTitle"]   = "MeetingQ Failed to Start",

        // ── Vision screenshot analysis (tooltips / exports) ─────────────
        ["LlmNotConfigured"] = "No LLM endpoint configured — add and activate a profile in Settings → Models",
        ["LlmVisionNoBaseUrl"] = "Vision base URL is not configured",
        ["LlmVisionNoApiKey"] = "Vision API Key is not configured",
        ["LlmVisionNoModelId"] = "Vision model ID is not configured",
        ["LlmProfileNoApiKey"] = "API Key is empty for LLM profile '{0}'",
        ["LlmProfileNoBaseUrl"] = "Base URL is empty for LLM profile '{0}'",
        ["LlmHttpError"] = "LLM returned an error (HTTP {0}) — check the API Key and endpoint configuration",
        ["VisionUnavailableCircuit"] = "Analysis temporarily unavailable (repeated failures)",
        ["VisionImageReadFailed"]    = "Failed to read image",
        ["VisionNoTranscript"]       = "(none)",
        ["VisionTopicNotDetected"]   = "(not detected)",
        ["VisionTimeout"]            = "Analysis timed out",
        ["VisionFailed"]             = "Analysis failed: {0}",
        ["VisionEmptyAnalysis"]      = "The model returned no usable analysis",
        ["VisionParseFailed"]        = "Failed to parse the response",

        // ── ASR ─────────────────────────────────────────────────────────
        ["AsrLocalError"]           = "Local speech recognition error: {0}",
        ["AsrModelDownloading"]     = "Downloading model {0} ...",
        ["AsrModelFileTooSmall"]    = "File too small ({0} bytes) — possibly corrupted",
        ["AsrModelDownloadFailed"]  = "Failed to download model {0}. Check your network and try again.",

        // ── Audio capture ───────────────────────────────────────────────
        ["AudioDefaultPlaybackDevice"] = "Default playback device",
    };
}
