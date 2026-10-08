using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public enum QuestionType
{
    Direct,
    Indirect,
    ActionRequired
}

public enum QuestionStatus
{
    Pending,
    Acknowledged,
    Dismissed
}

public class Question
{
    [Key]
    public int QuestionId { get; set; }

    public DateTime Timestamp { get; set; }

    public string? Speaker { get; set; }

    [Required]
    public string OriginalText { get; set; } = string.Empty;

    /// <summary>JSON array of extracted sub-questions.</summary>
    public string? ExtractedQuestions { get; set; }

    public QuestionType QuestionType { get; set; }

    public float Confidence { get; set; }

    public QuestionStatus Status { get; set; } = QuestionStatus.Pending;

    public int TopicId { get; set; }

    [ForeignKey(nameof(TopicId))]
    public Topic Topic { get; set; } = null!;
}
