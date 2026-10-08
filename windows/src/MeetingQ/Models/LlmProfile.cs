namespace MeetingQ.Models;

public class LlmProfile
{
    public Guid   Id       { get; set; } = Guid.NewGuid();
    public string Name     { get; set; } = string.Empty;
    public string BaseUrl  { get; set; } = string.Empty;
    public string ApiKey   { get; set; } = string.Empty;
    public string ModelId  { get; set; } = string.Empty;
    public bool   IsActive { get; set; }

    // Vision / multimodal model ID (falls back to ModelId when null)
    public string? VisionModelId { get; set; }
    // Context compression model ID (falls back to ModelId when null)
    public string? CompressionModelId { get; set; }
}
