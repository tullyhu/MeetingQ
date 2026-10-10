using MeetingQ.Infrastructure;
using MeetingQ.Models;
using MeetingQ.Services.Interfaces;
using Microsoft.Extensions.Logging;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MeetingQ.Services;

/// <summary>
/// OpenAI-compatible LLM service driven entirely by user-configured <see cref="LlmProfile"/> entries.
/// Active profile is selected in Settings; any OpenAI-compatible endpoint is supported.
/// </summary>
public class ConfigurableLlmService : ILlmService
{
    private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(100) };

    private readonly ILogger<ConfigurableLlmService> _logger;

    public ConfigurableLlmService(ILogger<ConfigurableLlmService> logger)
    {
        _logger = logger;
    }

    public Task<string> AnalyzeAsync(string prompt, CancellationToken cancellationToken = default)
    {
        var sys = LocalizationManager.Instance.IsEnglish
            ? "You are a meeting assistant. Answer concisely and accurately."
            : "你是会议助手，请简洁准确地回答。";
        return ChatAsync(sys, prompt, cancellationToken);
    }

    public Task<string> SummarizeAsync(IEnumerable<Transcript> transcripts, CancellationToken cancellationToken = default)
    {
        var combined = string.Join("\n", transcripts.Select(t => t.Text));
        var isEnglish = LocalizationManager.Instance.IsEnglish;
        if (string.IsNullOrWhiteSpace(combined))
            return Task.FromResult(JsonSerializer.Serialize(new
            {
                summary = isEnglish ? "No content" : "暂无内容",
                decisions = Array.Empty<string>()
            }));

        var prompt = isEnglish
            ? $"Analyze the following meeting transcript and return JSON in this format: {{\"summary\":\"key points summary\",\"decisions\":[\"decision 1\",\"decision 2\"]}}\n\nTranscript:\n{combined}"
            : $"请分析以下会议转录内容，以JSON格式返回，格式：{{\"summary\":\"要点摘要\",\"decisions\":[\"决策1\",\"决策2\"]}}\n\n转录内容：\n{combined}";

        var sys = isEnglish
            ? "You are a meeting-minutes assistant. Summarize the meeting in concise English. Return JSON only, no other content."
            : "你是会议纪要助手，请用简洁的中文总结会议内容，只返回JSON，不要其他内容。";

        return ChatAsync(sys, prompt, cancellationToken);
    }

    public Task<string> TestAsync(CancellationToken cancellationToken = default)
        => ChatAsync("You are a helpful assistant.", "Reply with exactly: ok", cancellationToken);

    public async Task<string> AnalyzeImageAsync(
        string systemPrompt,
        string userMessage,
        string imageBase64,
        string? modelOverride = null,
        CancellationToken cancellationToken = default)
    {
        var visionBaseUrl = SecureStorage.Load(SecureStorageKeys.VisionProviderBaseUrl);
        var visionApiKey = SecureStorage.Load(SecureStorageKeys.VisionProviderApiKey);
        var visionModelId = SecureStorage.Load(SecureStorageKeys.VisionProviderModelId);

        string baseUrl;
        string apiKey;
        string model;

        if (!string.IsNullOrWhiteSpace(visionBaseUrl) && !string.IsNullOrWhiteSpace(visionApiKey))
        {
            baseUrl = visionBaseUrl;
            apiKey = visionApiKey;
            model = modelOverride ?? visionModelId ?? string.Empty;
        }
        else
        {
            var profile = LlmProfileStore.GetActive();
            if (profile is null)
                throw new InvalidOperationException(LocalizationManager.Get("LlmNotConfigured"));
            baseUrl = profile.BaseUrl;
            apiKey = profile.ApiKey;
            model = modelOverride ?? profile.VisionModelId ?? profile.ModelId;
        }

        if (string.IsNullOrWhiteSpace(baseUrl))
            throw new InvalidOperationException(LocalizationManager.Get("LlmVisionNoBaseUrl"));
        if (string.IsNullOrWhiteSpace(apiKey))
            throw new InvalidOperationException(LocalizationManager.Get("LlmVisionNoApiKey"));
        if (string.IsNullOrWhiteSpace(model))
            throw new InvalidOperationException(LocalizationManager.Get("LlmVisionNoModelId"));

        // Build OpenAI content-array format for multimodal request.
        var messagesArray = new JsonArray
        {
            new JsonObject { ["role"] = "system", ["content"] = systemPrompt }
        };

        var userContent = new JsonArray
        {
            new JsonObject { ["type"] = "text", ["text"] = userMessage },
            new JsonObject
            {
                ["type"] = "image_url",
                ["image_url"] = new JsonObject
                {
                    ["url"] = $"data:image/jpeg;base64,{imageBase64}",
                    ["detail"] = "low"
                }
            }
        };

        messagesArray.Add(new JsonObject
        {
            ["role"] = "user",
            ["content"] = userContent
        });

        var bodyObj = new JsonObject
        {
            ["model"] = model,
            ["messages"] = messagesArray,
            ["max_tokens"] = 4096
        };

        var json = bodyObj.ToJsonString();

        _logger.LogDebug("[LLM-Vision] Request body ({Len} chars): {Body}", json.Length,
            SanitizeForLog(json));

        using var request = new HttpRequestMessage(HttpMethod.Post, baseUrl.TrimEnd('/') + "/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");

        _logger.LogInformation("[LLM-Vision] POST {Url}  model={Model}  img={Len}KB  provider={Provider}",
            request.RequestUri, model, imageBase64.Length / 1024,
            string.IsNullOrWhiteSpace(visionBaseUrl) ? "active-profile" : "vision-provider");

        return await SendLlmRequestAsync(request, cancellationToken);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    private async Task<string> ChatAsync(string systemPrompt, string userMessage, CancellationToken ct)
    {
        var profile = LlmProfileStore.GetActive();

        if (profile is null)
            throw new InvalidOperationException(LocalizationManager.Get("LlmNotConfigured"));

        if (string.IsNullOrWhiteSpace(profile.ApiKey))
            throw new InvalidOperationException(LocalizationManager.Format("LlmProfileNoApiKey", profile.Name));

        if (string.IsNullOrWhiteSpace(profile.BaseUrl))
            throw new InvalidOperationException(LocalizationManager.Format("LlmProfileNoBaseUrl", profile.Name));

        var url = profile.BaseUrl.TrimEnd('/') + "/chat/completions";

        var body = new
        {
            model    = profile.ModelId,
            messages = new[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user",   content = userMessage  }
            },
            max_tokens = 2048
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", profile.ApiKey);
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        _logger.LogDebug("[LLM] POST {Url}  model={Model}  len={Len}", url, profile.ModelId, userMessage.Length);

        return await SendLlmRequestAsync(request, ct);
    }

    /// <summary>Shared HTTP send + response parsing for all LLM request types.</summary>
    private async Task<string> SendLlmRequestAsync(HttpRequestMessage request, CancellationToken ct)
    {
        try
        {
            using var response = await _http.SendAsync(request, ct);
            var responseBody = await response.Content.ReadAsStringAsync(ct);

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogError("[LLM] HTTP {Status}: {Body}", (int)response.StatusCode,
                    TruncateForLog(responseBody));
                throw new HttpRequestException(LocalizationManager.Format("LlmHttpError", (int)response.StatusCode),
                    null, response.StatusCode);
            }

            _logger.LogDebug("[LLM] Response: {Body}", TruncateForLog(responseBody));

            using var doc = JsonDocument.Parse(responseBody);
            var msg = doc.RootElement
                .GetProperty("choices")[0]
                .GetProperty("message");

            string content = ExtractMessageContent(msg);

            _logger.LogInformation("[LLM] OK ({Len} chars): {Preview}",
                content.Length, content.Length > 80 ? content[..80] + "…" : content);

            return content;
        }
        catch (HttpRequestException)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[LLM] HTTP request or parse failed");
            var message = ex switch
            {
                TaskCanceledException => "LLM 请求超时，请检查网络连接",
                _ when ex.InnerException is System.Net.Sockets.SocketException => "无法连接 LLM 服务器，请检查接口地址和网络",
                _ => $"LLM 请求失败：{ex.Message}"
            };
            throw new InvalidOperationException(message, ex);
        }
    }

    private static string TruncateForLog(string text, int max = 500) =>
        text.Length > max ? text[..max] + "…" : text;

    // Strips inline base64 image payloads and truncates — never log raw images or full transcripts.
    private static string SanitizeForLog(string json)
    {
        const string marker = "data:image/jpeg;base64,";
        var idx = json.IndexOf(marker, StringComparison.Ordinal);
        if (idx >= 0)
        {
            var end = json.IndexOf('"', idx + marker.Length);
            json = end > idx
                ? string.Concat(json.AsSpan(0, idx + marker.Length), "[image omitted]", json.AsSpan(end))
                : json[..(idx + marker.Length)] + "[image omitted]";
        }
        return TruncateForLog(json);
    }

    private static string ExtractMessageContent(JsonElement msg)
    {
        if (!msg.TryGetProperty("content", out var contentEl))
        {
            if (msg.TryGetProperty("content_parts", out var parts))
                return ExtractContentFromArray(parts);
            return string.Empty;
        }

        return contentEl.ValueKind switch
        {
            JsonValueKind.String => contentEl.GetString() ?? string.Empty,
            JsonValueKind.Array  => ExtractContentFromArray(contentEl),
            JsonValueKind.Null   => string.Empty,
            _ => contentEl.GetRawText()
        };
    }

    private static string ExtractContentFromArray(JsonElement arr)
    {
        var sb = new StringBuilder();
        foreach (var item in arr.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
                sb.Append(item.GetString());
            else if (item.ValueKind == JsonValueKind.Object &&
                     item.TryGetProperty("type", out var typeEl) &&
                     typeEl.GetString() == "text" &&
                     item.TryGetProperty("text", out var textEl))
                sb.Append(textEl.GetString());
        }
        return sb.ToString();
    }
}
