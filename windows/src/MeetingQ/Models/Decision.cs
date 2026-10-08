using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public class Decision
{
    [Key]
    public int DecisionId { get; set; }

    public DateTime Timestamp { get; set; }

    [Required]
    public string DecisionText { get; set; } = string.Empty;

    public int TopicId { get; set; }

    [ForeignKey(nameof(TopicId))]
    public Topic Topic { get; set; } = null!;
}
