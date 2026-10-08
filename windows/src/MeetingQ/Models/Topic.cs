using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public class Topic
{
    [Key]
    public int TopicId { get; set; }

    [Required]
    public string Title { get; set; } = string.Empty;

    public DateTime StartTime { get; set; }

    public DateTime? EndTime { get; set; }

    public int OrderIndex { get; set; }

    public string? Summary { get; set; }

    public int SessionId { get; set; }

    [ForeignKey(nameof(SessionId))]
    public MeetingSession Session { get; set; } = null!;

    public ICollection<Transcript> Transcripts { get; set; } = new List<Transcript>();

    public ICollection<Decision> Decisions { get; set; } = new List<Decision>();

    public ICollection<Question> Questions { get; set; } = new List<Question>();

    public ICollection<ActionItem> ActionItems { get; set; } = new List<ActionItem>();
}
