using MeetingQ.Models;

namespace MeetingQ.Services.Interfaces;

public interface ILlmService
{
    Task<string> AnalyzeAsync(string prompt, CancellationToken cancellationToken = default);
    Task<string> SummarizeAsync(IEnumerable<Transcript> transcripts, CancellationToken cancellationToken = default);
    Task<string> TestAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Sends a multimodal request (text + base64 image) to the LLM endpoint.
    /// Uses <paramref name="modelOverride"/> if provided, otherwise falls back to
    /// the active profile's VisionModelId, then ModelId.
    /// </summary>
    Task<string> AnalyzeImageAsync(
        string systemPrompt,
        string userMessage,
        string imageBase64,
        string? modelOverride = null,
        CancellationToken cancellationToken = default);
}
