using System.Text.Json;

namespace MeetingQ.Services.Interfaces;

/// <summary>Result of a Vision screenshot analysis.</summary>
public class VisionAnalysisResult
{
    public string AiSummary { get; set; } = string.Empty;
    public string ContentType { get; set; } = "other";
    public List<string> KeyEntities { get; set; } = new();
    public List<string> KeyNumbers { get; set; } = new();
    public string OcrText { get; set; } = string.Empty;
    public string MeetingRelevance { get; set; } = "medium";
    public string SensitivityLevel { get; set; } = "low";
    /// <summary>Name of the active speaker visible in the video conferencing UI, extracted via OCR.</summary>
    public string? ActiveSpeakerName { get; set; }

    // ── Slide-level structured signals (aligned with macOS vision.txt 3.1.4) ──

    /// <summary>Key dates with context, e.g. "2026-09-10 launch".</summary>
    public List<string> KeyDates { get; set; } = new();

    /// <summary>Decisions written on slides/documents.</summary>
    public List<string> SlideDecisions { get; set; } = new();

    /// <summary>Action items written on slides ("task — owner — deadline").</summary>
    public List<string> SlideActionItems { get; set; } = new();

    /// <summary>Chart type (bar/line/pie/table) when the screenshot is a chart.</summary>
    public string? ChartType { get; set; }

    /// <summary>One-sentence key trend/comparison when the screenshot is a chart.</summary>
    public string? ChartInsight { get; set; }
}

public interface IVisionService
{
    /// <summary>Analyzes a screenshot image using the multimodal LLM.</summary>
    Task<VisionAnalysisResult> AnalyzeScreenshotAsync(
        string imagePath,
        string? currentTopic,
        List<string> surroundingTranscripts,
        CancellationToken ct = default);

    /// <summary>Tests the Vision LLM connection (sends a simple image + text prompt).</summary>
    Task<bool> TestConnectionAsync(CancellationToken ct = default);
}
