using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace MeetingQ.Models;

public class ActionItem
{
    [Key]
    public int ActionItemId { get; set; }

    public DateTime Timestamp { get; set; }

    /// <summary>负责人（人名或角色）</summary>
    [Required]
    public string AssignedTo { get; set; } = string.Empty;

    /// <summary>具体任务描述</summary>
    [Required]
    public string Task { get; set; } = string.Empty;

    /// <summary>截止时间（自然语言，如"本周五"，可为空）</summary>
    public string? Deadline { get; set; }

    public int TopicId { get; set; }

    [ForeignKey(nameof(TopicId))]
    public Topic Topic { get; set; } = null!;
}
