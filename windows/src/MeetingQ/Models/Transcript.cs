using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public class Transcript
{
    [Key]
    public int TranscriptId { get; set; }

    public DateTime Timestamp { get; set; }

    public string? Speaker { get; set; }

    [Required]
    public string Text { get; set; } = string.Empty;

    public bool IsFinal { get; set; }

    public float Confidence { get; set; }

    public int TopicId { get; set; }

    [ForeignKey(nameof(TopicId))]
    public Topic Topic { get; set; } = null!;
}
