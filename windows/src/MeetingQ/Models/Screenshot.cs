using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public class Screenshot
{
    [Key]
    public int ScreenshotId { get; set; }

    public DateTime Timestamp { get; set; }

    [Required]
    public string FilePath { get; set; } = string.Empty;

    public string? ImageHash { get; set; }

    // ── AI / Vision analysis fields ────────────────────────────────────────

    /// <summary>AI-generated description of the screenshot content.</summary>
    public string? AISummary { get; set; }

    /// <summary>OCR text extracted from the screenshot.</summary>
    public string? OcrText { get; set; }

    /// <summary>Type of content: slide/chart/document/whiteboard/code/chat/browser/other.</summary>
    public string? ContentType { get; set; }

    /// <summary>JSON array of key entities extracted from the screenshot.</summary>
    public string? KeyEntities { get; set; }

    /// <summary>JSON array of key numbers/figures extracted from the screenshot.</summary>
    public string? KeyNumbers { get; set; }

    /// <summary>Relevance to the current meeting: high/medium/low.</summary>
    public string? MeetingRelevance { get; set; }

    /// <summary>Sensitivity level: low/medium/high.</summary>
    public string? SensitivityLevel { get; set; }

    /// <summary>Analysis status: pending/processing/ready/failed/skipped.</summary>
    public string? AnalysisStatus { get; set; }

    /// <summary>Name of the active speaker visible in the video conferencing UI, extracted by Vision analysis.</summary>
    public string? ActiveSpeakerName { get; set; }

    /// <summary>FK to the related Topic (optional, populated by topic detection).</summary>
    public int? RelatedTopicId { get; set; }

    // ── Relationships ──────────────────────────────────────────────────────

    public int SessionId { get; set; }

    [ForeignKey(nameof(SessionId))]
    public MeetingSession Session { get; set; } = null!;
}
