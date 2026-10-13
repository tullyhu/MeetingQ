using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public enum SessionStatus
{
    Idle,
    Monitoring,
    Ended,
    Saved
}

public class MeetingSession
{
    [Key]
    public int SessionId { get; set; }

    public DateTime StartTime { get; set; }

    public DateTime? EndTime { get; set; }

    public SessionStatus Status { get; set; } = SessionStatus.Idle;

    public string? Title { get; set; }

    public string? Summary { get; set; }

    /// <summary>Minutes template id used for the final structured minutes (null = legacy prompt).</summary>
    public string? TemplateId { get; set; }

    /// <summary>Full structured minutes JSON (Services/StructuredMinutes), when generated via a template.</summary>
    public string? MinutesJson { get; set; }

    /// <summary>Quality score 0-100 from MinutesQualityAssessor (null = not assessed).</summary>
    public int? QualityScore { get; set; }

    /// <summary>FK to the cross-meeting theme this session was classified into (null = unclassified).</summary>
    public int? ThemeId { get; set; }

    [ForeignKey(nameof(ThemeId))]
    public MeetingTheme? Theme { get; set; }

    public ICollection<Topic> Topics { get; set; } = new List<Topic>();

    public ICollection<Screenshot> Screenshots { get; set; } = new List<Screenshot>();
}
