using System.ComponentModel.DataAnnotations;

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

    public ICollection<Topic> Topics { get; set; } = new List<Topic>();

    public ICollection<Screenshot> Screenshots { get; set; } = new List<Screenshot>();
}
