using MeetingQ.Infrastructure;
using MeetingQ.Services.Interfaces;
using Microsoft.Extensions.Logging;
using System.IO;
using System.Net.Http;
using System.Text.Json;

namespace MeetingQ.Services;

/// <summary>
/// Vision screenshot analysis service.
/// Reads a JPEG screenshot, encodes it as base64, and sends it to the multimodal LLM
/// for structured analysis (content type, OCR, key entities, etc.).
/// Uses SemaphoreSlim to serialize concurrent requests (one at a time).
/// </summary>
public class VisionService : IVisionService
{
    private readonly ILlmService _llm;
    private readonly ILogger<VisionService> _logger;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private const int MaxRetries = 2;
    private const int MaxConsecutiveFails = 3;
    private static readonly TimeSpan CircuitCooldown = TimeSpan.FromSeconds(60);
    private int _consecutiveFails;
    private DateTime _circuitOpenUntil = DateTime.MinValue;

    public VisionService(ILlmService llm, ILogger<VisionService> logger)
    {
        _llm = llm;
        _logger = logger;
    }

    private void RegisterFailure()
    {
        _consecutiveFails++;
        if (_consecutiveFails >= MaxConsecutiveFails)
            _circuitOpenUntil = DateTime.UtcNow + CircuitCooldown;
    }

    // Retries transient failures (network / timeout) with 1s/2s backoff; 4xx is not retried.
    private async Task<string> CallLlmWithRetryAsync(
        string systemPrompt, string userMessage, string base64, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await _llm.AnalyzeImageAsync(systemPrompt, userMessage, base64,
                    cancellationToken: ct);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                if (attempt >= MaxRetries) throw;
                var delay = TimeSpan.FromSeconds(1 << attempt);
                _logger.LogWarning("[Vision] Timeout (attempt {N}/{Max}) — retrying in {Delay}s",
                    attempt + 1, MaxRetries + 1, delay.TotalSeconds);
                await Task.Delay(delay, ct);
            }
            catch (HttpRequestException ex) when (attempt < MaxRetries && !IsClientError(ex))
            {
                var delay = TimeSpan.FromSeconds(1 << attempt);
                _logger.LogWarning("[Vision] Network error (attempt {N}/{Max}): {Msg} — retrying in {Delay}s",
                    attempt + 1, MaxRetries + 1, ex.Message, delay.TotalSeconds);
                await Task.Delay(delay, ct);
            }
            catch (InvalidOperationException ex) when (attempt < MaxRetries && !ct.IsCancellationRequested
                && IsTransient(ex))
            {
                var delay = TimeSpan.FromSeconds(1 << attempt);
                _logger.LogWarning("[Vision] Transient error (attempt {N}/{Max}): {Msg} — retrying in {Delay}s",
                    attempt + 1, MaxRetries + 1, ex.Message, delay.TotalSeconds);
                await Task.Delay(delay, ct);
            }
        }
    }

    private static bool IsClientError(HttpRequestException ex) =>
        ex.StatusCode is >= System.Net.HttpStatusCode.BadRequest
                         and < System.Net.HttpStatusCode.InternalServerError
        || ex.Message.Contains("HTTP 4", StringComparison.Ordinal);

    // Wrapped timeout / socket errors from ConfigurableLlmService.
    private static bool IsTransient(InvalidOperationException ex) =>
        ex.InnerException is TaskCanceledException or System.Net.Sockets.SocketException;

    public async Task<VisionAnalysisResult> AnalyzeScreenshotAsync(
        string imagePath,
        string? currentTopic,
        List<string> surroundingTranscripts,
        CancellationToken ct = default)
    {
        // Rate-limit: skip while the circuit is open (re-arms 60s after the 3rd failure,
        // so a single half-open probe is allowed through once the cooldown elapses).
        if (_consecutiveFails >= MaxConsecutiveFails && DateTime.UtcNow < _circuitOpenUntil)
        {
            _logger.LogWarning("[Vision] Skipping analysis — {Count} consecutive failures (circuit open)",
                _consecutiveFails);
            return CreateFallbackResult(LocalizationManager.Get("VisionUnavailableCircuit"));
        }

        await _gate.WaitAsync(ct);
        try
        {
            // Read and encode the image
            byte[] imageBytes;
            try
            {
                imageBytes = await File.ReadAllBytesAsync(imagePath, ct);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[Vision] Failed to read image: {Path}", imagePath);
                return CreateFallbackResult(LocalizationManager.Get("VisionImageReadFailed"));
            }

            var base64 = Convert.ToBase64String(imageBytes);
            var isEnglish = LocalizationManager.Instance.IsEnglish;
            var transcripts = surroundingTranscripts.Count > 0
                ? string.Join("\n", surroundingTranscripts.TakeLast(6))
                : LocalizationManager.Get("VisionNoTranscript");

            // Build the Vision prompt (matching vision.txt 3.1.4)
            var topicText = currentTopic ?? LocalizationManager.Get("VisionTopicNotDetected");
            var transcriptsText = transcripts;
            var userMessage = isEnglish
                ? "[Meeting context]\nCurrent topic: " + topicText + "\n\n[Transcript around the screenshot time]\n" + transcriptsText + "\n\n[Task]\nAnalyze the screenshot, focusing on:\n1. What is shown on screen (document/slide/data chart/whiteboard/code/chat window/other)\n2. Key data, conclusions, or information\n3. Relevance to the current meeting discussion\n4. Readable text in the image (OCR)\n5. The name of the person currently speaking in the video-conference UI (the current speaker's name is usually shown at the top/bottom/corner of the screen, e.g. \"John is speaking\", \"Jane (speaking)\")\n\n[Important] Output ONLY the following JSON format; field names must be strictly English lowercase + underscore:\n{\n  \"ai_summary\": \"2-4 sentences describing the image content and its relation to the meeting\",\n  \"content_type\": \"slide/chart/document/whiteboard/code/chat/browser/other\",\n  \"key_entities\": [\"keyword1\", \"keyword2\"],\n  \"key_numbers\": [\"12%\", \"500K\"],\n  \"ocr_text\": \"readable text in the image (key parts)\",\n  \"meeting_relevance\": \"high/medium/low\",\n  \"sensitivity_level\": \"low/medium/high\",\n  \"active_speaker_name\": \"name of the current speaker (if visible), otherwise null\"\n}\nOutput JSON only, no explanations, no Chinese field names."
                : "【会议背景】\n当前议题: " + topicText + "\n\n【截图时间点前后的转写】\n" + transcriptsText + "\n\n【任务】\n分析截图内容,重点关注:\n1. 屏幕上展示的是什么(文档/幻灯片/数据图表/白板/代码/聊天窗口/其他)\n2. 关键数据、结论或信息\n3. 与当前会议讨论的关联性\n4. 图中可读文字(OCR)\n5. 视频会议UI中正在发言的人的名字(通常在屏幕顶部/底部/角落显示当前讲话人名称，如\"张三 正在发言\"、\"李四 (发言中)\"等)\n\n【重要】仅输出以下 JSON 格式,字段名严格使用英文小写+下划线:\n{\n  \"ai_summary\": \"2~4句描述图中内容和会议关联\",\n  \"content_type\": \"slide/chart/document/whiteboard/code/chat/browser/other\",\n  \"key_entities\": [\"关键词1\", \"关键词2\"],\n  \"key_numbers\": [\"12%\", \"50万\"],\n  \"ocr_text\": \"图中可读文字(关键部分)\",\n  \"meeting_relevance\": \"high/medium/low\",\n  \"sensitivity_level\": \"low/medium/high\",\n  \"active_speaker_name\": \"当前发言人的名字(如能看到)，否则填null\"\n}\n只输出 JSON,不要解释,不要使用中文字段名。";

            var systemPrompt = isEnglish
                ? "You are a meeting visual-content analysis assistant. Analyze this meeting screenshot and produce a structured description."
                : "你是会议视觉内容分析助手。请分析这张会议截图并生成结构化描述。";

            string response;
            try
            {
                response = await CallLlmWithRetryAsync(systemPrompt, userMessage, base64, ct);
            }
            catch (OperationCanceledException)
            {
                _logger.LogWarning("[Vision] Request timed out for {Path}", imagePath);
                RegisterFailure();
                return CreateFallbackResult(LocalizationManager.Get("VisionTimeout"));
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[Vision] LLM call failed for {Path}", imagePath);
                RegisterFailure();
                return CreateFallbackResult(LocalizationManager.Format("VisionFailed", ex.Message));
            }

            // Parse the JSON response
            try
            {
                var result = ParseResult(response);
                _consecutiveFails = 0; // reset on success

                // If the response parsed but ai_summary is empty, the model
                // likely returned valid JSON without the expected fields.
                if (string.IsNullOrWhiteSpace(result.AiSummary))
                {
                    _logger.LogWarning("[Vision] Response lacks ai_summary. Raw: {Resp}", response);
                    AppLog.Warn("VisionService", $"模型返回内容(前200字): {response[..Math.Min(response.Length, 200)]}");
                    return CreateFallbackResult(LocalizationManager.Get("VisionEmptyAnalysis"));
                }

                _logger.LogInformation("[Vision] OK — type={Type} relevance={Relevance}",
                    result.ContentType, result.MeetingRelevance);
                return result;
            }
            catch (JsonException ex)
            {
                _logger.LogError(ex, "[Vision] Failed to parse response: {Resp}", response);
                RegisterFailure();
                return CreateFallbackResult(LocalizationManager.Get("VisionParseFailed"));
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<bool> TestConnectionAsync(CancellationToken ct = default)
    {
        try
        {
            // Use a minimal test: send a small known base64 (1-pixel JPEG) to verify the
            // multimodal endpoint responds. Fall back to text-only test if vision fails.
            var testImage = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYI4Q/SFhSRFJiMkVic4EzRjRzU5I0nB/9oADAMBAAIRAxEAPwDn+/+f/9k=";
            var sysPrompt = "You are a helpful assistant.";
            var result = await _llm.AnalyzeImageAsync(sysPrompt,
                "Reply with exactly: ok", testImage, cancellationToken: ct);
            var trimmed = result.Trim().TrimEnd('.', '!', '。').Trim();
            return trimmed.Equals("ok", StringComparison.OrdinalIgnoreCase)
                || (trimmed.Length <= 10 && trimmed.StartsWith("ok", StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Vision] Connection test failed");
            return false;
        }
    }

    // ── Private ──────────────────────────────────────────────────────────

    private static VisionAnalysisResult ParseResult(string json)
    {
        // Extract JSON from possible markdown fences
        var start = json.IndexOf('{');
        var end = json.LastIndexOf('}');
        if (start >= 0 && end > start)
            json = json[start..(end + 1)];

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        // Try snake_case first, then camelCase, then any text-like field
        var result = new VisionAnalysisResult
        {
            AiSummary = GetStringProperty(root, "ai_summary", "aiSummary", "summary", "description", "text", "content", "response")
                       ?? ExtractFirstStringValue(root)
                       ?? string.Empty,
            ContentType = GetStringProperty(root, "content_type", "contentType", "type") ?? "other",
            OcrText = GetStringProperty(root, "ocr_text", "ocrText", "ocr") ?? string.Empty,
            MeetingRelevance = GetStringProperty(root, "meeting_relevance", "meetingRelevance", "relevance") ?? "medium",
            SensitivityLevel = GetStringProperty(root, "sensitivity_level", "sensitivityLevel", "sensitivity") ?? "low",
            ActiveSpeakerName = GetStringProperty(root, "active_speaker_name", "activeSpeakerName", "speaker_name", "speakerName")
        };

        if (root.TryGetProperty("key_entities", out var ke) && ke.ValueKind == JsonValueKind.Array)
            result.KeyEntities = ke.EnumerateArray().Select(x => x.GetString() ?? string.Empty)
                .Where(x => x.Length > 0).ToList();
        else if (root.TryGetProperty("keyEntities", out ke) && ke.ValueKind == JsonValueKind.Array)
            result.KeyEntities = ke.EnumerateArray().Select(x => x.GetString() ?? string.Empty)
                .Where(x => x.Length > 0).ToList();

        if (root.TryGetProperty("key_numbers", out var kn) && kn.ValueKind == JsonValueKind.Array)
            result.KeyNumbers = kn.EnumerateArray().Select(x => x.GetString() ?? string.Empty)
                .Where(x => x.Length > 0).ToList();
        else if (root.TryGetProperty("keyNumbers", out kn) && kn.ValueKind == JsonValueKind.Array)
            result.KeyNumbers = kn.EnumerateArray().Select(x => x.GetString() ?? string.Empty)
                .Where(x => x.Length > 0).ToList();

        return result;
    }

    /// <summary>Returns the first non-empty string property from the given field names.</summary>
    private static string? GetStringProperty(JsonElement root, params string[] names)
    {
        foreach (var name in names)
        {
            if (root.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String)
            {
                var val = el.GetString();
                if (!string.IsNullOrWhiteSpace(val))
                    return val;
            }
        }
        return null;
    }

    /// <summary>Fallback: recursively find the first non-empty string value in the JSON object.</summary>
    private static string? ExtractFirstStringValue(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.String)
        {
            var v = root.GetString();
            if (!string.IsNullOrWhiteSpace(v)) return v;
        }
        if (root.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in root.EnumerateObject())
            {
                if (prop.Value.ValueKind == JsonValueKind.String)
                {
                    var v = prop.Value.GetString();
                    if (!string.IsNullOrWhiteSpace(v) && v.Length > 5)
                        return v;
                }
                var nested = ExtractFirstStringValue(prop.Value);
                if (nested is not null) return nested;
            }
        }
        if (root.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in root.EnumerateArray())
            {
                var nested = ExtractFirstStringValue(item);
                if (nested is not null) return nested;
            }
        }
        return null;
    }

    private static VisionAnalysisResult CreateFallbackResult(string errorHint)
    {
        return new VisionAnalysisResult
        {
            AiSummary = $"[{errorHint}]",
            ContentType = "other",
            MeetingRelevance = "low"
        };
    }
}
