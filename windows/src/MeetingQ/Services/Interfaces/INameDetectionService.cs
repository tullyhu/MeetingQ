namespace MeetingQ.Services.Interfaces;

public class DetectionResult
{
    public bool IsDetected { get; set; }
    public float Confidence { get; set; }
    public string? MatchedName { get; set; }
    public string? OriginalText { get; set; }
    public string[]? ExtractedQuestions { get; set; }
    public int DetectionLayer { get; set; }
}

public interface INameDetectionService
{
    /// <summary>Runs the 3-layer detection pipeline synchronously (Layers 0 and 1 are fast; Layer 2 is async-capable).</summary>
    DetectionResult Detect(string text);

    /// <summary>Full async detection including LLM Layer 2.</summary>
    Task<DetectionResult> DetectAsync(string text, CancellationToken cancellationToken = default);

    /// <summary>Reloads user names/nicknames from SecureStorage and rebuilds the detection regex.
    /// Call after the user saves identity settings.</summary>
    void ReloadNames();
}
