using MeetingQ.Infrastructure;
using MeetingQ.Services.Interfaces;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using System.Text.RegularExpressions;
using static MeetingQ.Infrastructure.PinyinHelper;

namespace MeetingQ.Services;

/// <summary>
/// 3-layer name detection pipeline:
///   Layer 0 (&lt;50ms):  Local regex on user names/nicknames
///   Layer 1 (&lt;200ms): Chinese interrogative / directed-speech patterns
///   Layer 2 (1–3s):   LLM semantic analysis — sub-questions, urgency
/// Names are reloaded from SecureStorage each session via <see cref="ReloadNames"/>.
/// </summary>
public class NameDetectionService : INameDetectionService, IDisposable
{
    private readonly ILlmService _llmService;
    private readonly ILogger<NameDetectionService> _logger;

    // Compiled once per session; rebuilt when names change via ReloadNames().
    private Regex? _nameRegex;
    private string[] _loadedNames = Array.Empty<string>();
    private string   _userRole    = string.Empty;

    // Auto-learned ASR variants: batched + debounced to avoid per-utterance disk I/O.
    private const int MaxAsrVariants   = 200;
    private const int FlushThreshold   = 5;
    private static readonly TimeSpan FlushDelay = TimeSpan.FromSeconds(10);
    private readonly object       _variantLock = new();
    private readonly List<string> _pendingVariants = new();
    private Timer? _saveTimer;

    // Layer 1: Chinese words/particles that signal a question or directed speech
    private static readonly string[] QuestionParticles =
        { "吗", "呢", "么", "嘛", "啊" };

    private static readonly string[] InterrogativeWords =
        { "什么", "怎么", "为什么", "哪里", "哪个", "哪些", "谁", "多少", "几", "如何", "是否" };

    private static readonly string[] DirectedPhrases =
        { "你觉得", "你认为", "你说", "你来", "你有", "你能", "请你", "问你", "想问你",
          "你的意见", "你的看法", "你怎么看", "你们觉得", "你们认为" };

    // Role words that anchor a directed phrase to the user (e.g. "主持人你觉得…").
    private static readonly string[] RoleWords =
        { "主持人", "老师", "经理", "主管", "领导", "组长", "总监", "老板", "书记" };

    public NameDetectionService(ILlmService llmService, ILogger<NameDetectionService> logger)
    {
        _llmService = llmService;
        _logger     = logger;
        ReloadNames();
    }

    // ── Public API ──────────────────────────────────────────────────────

    /// <summary>Re-reads user identity from SecureStorage and rebuilds the name regex.</summary>
    public void ReloadNames()
    {
        var names = new List<string>();

        var userName = SecureStorage.Load(SecureStorageKeys.UserName);
        if (!string.IsNullOrWhiteSpace(userName))
            names.AddRange(userName.Split(',').Select(n => n.Trim()).Where(n => n.Length > 0));

        var nicknames = SecureStorage.Load(SecureStorageKeys.UserNicknames);
        if (!string.IsNullOrWhiteSpace(nicknames))
            names.AddRange(nicknames.Split(',').Select(n => n.Trim()).Where(n => n.Length > 0));

        // ASR同音变体 — 加入 Layer 0 regex，效果等同于昵称
        var asrVariants = SecureStorage.Load(SecureStorageKeys.UserAsrVariants);
        if (!string.IsNullOrWhiteSpace(asrVariants))
            names.AddRange(asrVariants.Split(',').Select(n => n.Trim()).Where(n => n.Length > 0));

        _loadedNames = names.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        _userRole    = SecureStorage.Load(SecureStorageKeys.UserRole)?.Trim() ?? string.Empty;

        if (_loadedNames.Length > 0)
        {
            var pattern = string.Join("|", _loadedNames.Select(Regex.Escape));
            _nameRegex = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.Compiled);
            _logger.LogInformation("[NameDetect] Watching for names: {Names}", string.Join(", ", _loadedNames));
        }
        else
        {
            _nameRegex = null;
            _logger.LogWarning("[NameDetect] No user names configured — Layer 0 disabled");
        }
    }

    public DetectionResult Detect(string text)
    {
        var layer0 = RunLayer0(text);
        if (layer0.IsDetected) return layer0;

        return RunLayer1(text);
    }

    public async Task<DetectionResult> DetectAsync(string text, CancellationToken cancellationToken = default)
    {
        var result = Detect(text);
        if (result.IsDetected)
            return await RunLayer2Async(text, result, cancellationToken);
        return result;
    }

    // ── Layer 0: name regex + pinyin fuzzy match ────────────────────────

    private DetectionResult RunLayer0(string text)
    {
        // Fast path: exact regex match on registered names / nicknames / ASR variants
        if (_nameRegex is not null)
        {
            var match = _nameRegex.Match(text);
            if (match.Success)
            {
                _logger.LogInformation("[NameDetect] Layer0 regex hit: matched '{Name}' in: {Text}",
                    match.Value, text.Length > 60 ? text[..60] + "…" : text);
                return new DetectionResult
                {
                    IsDetected     = true,
                    Confidence     = 0.85f,
                    MatchedName    = match.Value,
                    OriginalText   = text,
                    DetectionLayer = 0
                };
            }
        }

        // Pinyin fuzzy match: catches same-pronunciation homophones missed by exact regex
        // (e.g. "途莉" → also matches "涂利", "图里", "土里" automatically)
        foreach (var name in _loadedNames)
        {
            if (name.Length < 2) continue; // single-char too ambiguous for pinyin match
            var pinyinMatch = FindPinyinMatch(name, text);
            if (pinyinMatch is not null && pinyinMatch != name) // exact already caught above
            {
                _logger.LogInformation(
                    "[NameDetect] Layer0 pinyin hit: '{Name}'→'{Match}' in: {Text}",
                    name, pinyinMatch, text.Length > 60 ? text[..60] + "…" : text);

                // Auto-add the matched word to ASR variants so subsequent
                // detections hit the fast exact-regex path instead of the
                // expensive sliding-window pinyin scan.
                AutoAddAsrVariant(pinyinMatch);

                return new DetectionResult
                {
                    IsDetected     = true,
                    Confidence     = 0.75f, // slightly lower than exact match
                    MatchedName    = pinyinMatch,
                    OriginalText   = text,
                    DetectionLayer = 0
                };
            }
        }

        return new DetectionResult { IsDetected = false, OriginalText = text, DetectionLayer = 0 };
    }

    private void AutoAddAsrVariant(string variant)
    {
        lock (_variantLock)
        {
            // Guard: already known or already queued — skip disk I/O and regex rebuild
            if (_loadedNames.Contains(variant, StringComparer.OrdinalIgnoreCase) ||
                _pendingVariants.Contains(variant, StringComparer.OrdinalIgnoreCase))
                return;

            _pendingVariants.Add(variant);
            if (_pendingVariants.Count >= FlushThreshold)
                FlushVariantsLocked();
            else
            {
                _saveTimer ??= new Timer(_ => FlushPendingVariants());
                _saveTimer.Change(FlushDelay, Timeout.InfiniteTimeSpan);
            }
        }
    }

    private void FlushPendingVariants()
    {
        lock (_variantLock) FlushVariantsLocked();
    }

    // Caller must hold _variantLock.
    private void FlushVariantsLocked()
    {
        if (_pendingVariants.Count == 0) return;
        try
        {
            var existing = SecureStorage.Load(SecureStorageKeys.UserAsrVariants);
            var list = string.IsNullOrEmpty(existing)
                ? new List<string>()
                : existing.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();

            foreach (var v in _pendingVariants)
                if (!list.Contains(v, StringComparer.OrdinalIgnoreCase))
                    list.Add(v);
            _pendingVariants.Clear();

            // Cap the list — drop oldest variants beyond the limit.
            if (list.Count > MaxAsrVariants)
                list = list.Skip(list.Count - MaxAsrVariants).ToList();

            SecureStorage.Save(SecureStorageKeys.UserAsrVariants, string.Join(",", list));
            _saveTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            ReloadNames();
            _logger.LogInformation("[NameDetect] Flushed learned ASR variants (total {Count})", list.Count);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[NameDetect] Failed to save ASR variants");
        }
    }

    public void Dispose()
    {
        lock (_variantLock)
        {
            _saveTimer?.Dispose();
            _saveTimer = null;
            FlushVariantsLocked();
        }
    }

    // ── Layer 1: Chinese patterns ───────────────────────────────────────

    private DetectionResult RunLayer1(string text)
    {
        // Check if text ends with a question particle (common in Mandarin questions)
        bool endsWithQuestion = QuestionParticles.Any(p => text.TrimEnd('，', '。', '！', ' ').EndsWith(p));

        // Check for interrogative words (疑问词)
        bool hasInterrogative = InterrogativeWords.Any(w => text.Contains(w));

        // Check for phrases explicitly directed at the user
        bool hasDirectedPhrase = DirectedPhrases.Any(p => text.Contains(p));

        // "你觉得…"-style phrases alone are usually aimed at someone else — only treat
        // them as directed when the text also names the user (or a role they hold).
        if (hasDirectedPhrase && !HasUserAnchor(text))
            return new DetectionResult
            {
                IsDetected     = false,
                Confidence     = 0.2f,
                OriginalText   = text,
                DetectionLayer = 1
            };

        if (hasDirectedPhrase || (endsWithQuestion && hasInterrogative))
        {
            float confidence = hasDirectedPhrase ? 0.7f : 0.5f;
            _logger.LogInformation(
                "[NameDetect] Layer1 hit: directed={D} endQ={Q} interrog={I} text='{T}'",
                hasDirectedPhrase, endsWithQuestion, hasInterrogative,
                text.Length > 60 ? text[..60] + "…" : text);

            return new DetectionResult
            {
                IsDetected     = true,
                Confidence     = confidence,
                OriginalText   = text,
                DetectionLayer = 1
            };
        }

        return new DetectionResult { IsDetected = false, OriginalText = text, DetectionLayer = 1 };
    }

    private bool HasUserAnchor(string text)
    {
        if (_nameRegex?.IsMatch(text) == true) return true;
        if (!string.IsNullOrEmpty(_userRole) && text.Contains(_userRole)) return true;
        return RoleWords.Any(w => text.Contains(w));
    }

    // ── Layer 2: LLM analysis ───────────────────────────────────────────

    private async Task<DetectionResult> RunLayer2Async(
        string text,
        DetectionResult preliminary,
        CancellationToken cancellationToken)
    {
        var namesHint = _loadedNames.Length > 0
            ? $"用户姓名/昵称：{string.Join("、", _loadedNames)}"
            : "（用户未配置名字）";
        var roleHint = string.IsNullOrEmpty(_userRole) ? string.Empty
            : $"\n用户角色：{_userRole}（可据此判断该角色相关的职责性问题是否指向该用户）";

        var prompt =
            $$"""
            {{namesHint}}{{roleHint}}

            会议中说了这句话："{{text}}"

            请判断这句话是否直接针对上述用户本人：
            - 判断依据：句中出现用户的姓名或昵称（含语音识别可能造成的同音字误识别），或有明确点名该用户的上下文，或问题明显与其角色职责相关且上下文隐含指向该用户。
            - 注意：句中出现"你"、"你来"、"你觉得"等泛称，但未出现用户姓名/昵称时，通常是在对其他人说话，应返回 directed=false。

            只返回JSON，格式：{"directed":true,"questions":["具体问题"]}
            若不是针对用户：{"directed":false,"questions":[]}
            """;

        try
        {
            var response = await _llmService.AnalyzeAsync(prompt, cancellationToken);
            if (string.IsNullOrWhiteSpace(response)) return preliminary;

            // Extract JSON even if wrapped in markdown code fences
            var jsonStart = response.IndexOf('{');
            var jsonEnd   = response.LastIndexOf('}');
            if (jsonStart < 0 || jsonEnd <= jsonStart) return preliminary;
            var json = response[jsonStart..(jsonEnd + 1)];

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            bool directed = root.TryGetProperty("directed", out var d) && d.GetBoolean();
            if (!directed)
            {
                preliminary.IsDetected = false;
                return preliminary;
            }

            var questions = new List<string>();
            if (root.TryGetProperty("questions", out var q) && q.ValueKind == JsonValueKind.Array)
                foreach (var item in q.EnumerateArray())
                    if (item.GetString() is string s && !string.IsNullOrWhiteSpace(s))
                        questions.Add(s);

            preliminary.ExtractedQuestions = questions.Count > 0
                ? questions.ToArray()
                : new[] { text };
            preliminary.DetectionLayer = 2;
            // Confidence by evidence quality: explicit name mention + concrete
            // extracted question = high; LLM-only inference = moderate.
            bool mentionsName = _loadedNames.Any(n =>
                n.Length > 0 && text.Contains(n, StringComparison.OrdinalIgnoreCase));
            preliminary.Confidence = mentionsName && questions.Count > 0 ? 0.9f : 0.6f;

            _logger.LogInformation("[NameDetect] Layer2 result: directed={D} questions={Q}",
                directed, questions.Count);

            return preliminary;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[NameDetect] Layer2 LLM analysis failed, using Layer1 result");
            return preliminary;
        }
    }
}
