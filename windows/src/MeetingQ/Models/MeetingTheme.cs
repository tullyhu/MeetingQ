using System.ComponentModel.DataAnnotations;

namespace MeetingQ.Models;

/// <summary>
/// A cross-meeting theme (an ongoing project/activity spanning multiple sessions),
/// mirroring macOS MeetingTheme. Keywords drive candidate pre-filtering for the
/// LLM-based classifier (Services/ThemeClassifier.cs).
/// </summary>
public class MeetingTheme
{
    [Key]
    public int ThemeId { get; set; }

    [Required]
    public string Name { get; set; } = string.Empty;

    /// <summary>JSON array of keywords (max 10), merged on each attach.</summary>
    public string KeywordsJson { get; set; } = "[]";

    public DateTime CreatedAt { get; set; } = DateTime.Now;

    public bool IsArchived { get; set; }

    public ICollection<MeetingSession> Sessions { get; set; } = new List<MeetingSession>();
}
