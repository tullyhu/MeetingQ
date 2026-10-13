using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Secure key-value storage backed by Windows DPAPI (ProtectedData).
/// API keys are never stored in plaintext — always encrypted per-user (CurrentUser scope).
/// Storage directory is user-configurable; see <see cref="StorageConfig"/>.
/// </summary>
public static class SecureStorage
{
    // Property (not field) so every access picks up the user-selected directory.
    private static string StorageDir => StorageConfig.GetStorageDir();

    /// <summary>Encrypts <paramref name="value"/> with DPAPI and saves to disk.</summary>
    public static void Save(string key, string value)
    {
        Directory.CreateDirectory(StorageDir);
        var plainBytes = Encoding.UTF8.GetBytes(value);
        var encrypted  = ProtectedData.Protect(plainBytes, GetEntropy(key), DataProtectionScope.CurrentUser);
        // Atomic write: temp file + move so a crash mid-write can't corrupt the value.
        var path = GetFilePath(key);
        var tmp  = path + ".tmp";
        File.WriteAllBytes(tmp, encrypted);
        File.Move(tmp, path, overwrite: true);
    }

    /// <summary>Loads and decrypts the value for <paramref name="key"/>. Returns null if not found.</summary>
    public static string? Load(string key)
    {
        var path = GetFilePath(key);
        if (!File.Exists(path)) return null;

        try
        {
            var encrypted  = File.ReadAllBytes(path);
            var plainBytes = ProtectedData.Unprotect(encrypted, GetEntropy(key), DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plainBytes);
        }
        catch (Exception ex) when (ex is CryptographicException or IOException or UnauthorizedAccessException)
        {
            // Corrupted or undecryptable file (e.g. crashed mid-write, different user) —
            // delete it and behave as if the key doesn't exist.
            AppLog.Warn("SecureStorage", $"无法读取 '{key}' 的存储文件，已删除损坏文件: {ex.Message}");
            try { File.Delete(path); } catch { }
            return null;
        }
    }

    /// <summary>Deletes the stored value for <paramref name="key"/>.</summary>
    public static void Delete(string key)
    {
        var path = GetFilePath(key);
        if (File.Exists(path)) File.Delete(path);
    }

    public static bool Exists(string key) => File.Exists(GetFilePath(key));

    private static string GetFilePath(string key)
    {
        var safe = string.Concat(key.Select(c => char.IsLetterOrDigit(c) || c == '_' || c == '-' ? c : '_'));
        return Path.Combine(StorageDir, $"{safe}.dat");
    }

    private static byte[] GetEntropy(string key) => Encoding.UTF8.GetBytes($"MeetingQ:{key}");
}

/// <summary>Well-known storage keys.</summary>
public static class SecureStorageKeys
{
    // User identity (non-secret, stored here for simplicity)
    public const string UserName        = "user_name";
    public const string UserNicknames   = "user_nicknames";
    public const string UserAsrVariants = "user_asr_variants"; // ASR同音误识词
    public const string UserRole        = "user_role";

    // LLM profiles (JSON array)
    public const string LlmProfiles = "llm_profiles";
    // Screenshot target window
    public const string CaptureWindowTitle = "capture_window_title";
    // Microphone capture
    public const string MicEnabled    = "mic_enabled";
    public const string MicDeviceName = "mic_device_name";
    // W5 meeting auto-detection mode: "off" | "prompt" (default) | "auto"
    public const string MeetingAutoDetectMode = "meeting_auto_detect_mode";
    // Local ASR model directory — deprecated, replaced by AST server config
    public const string LocalAsrModelDir = "local_asr_model_dir";

    // First-run flags
    public const string PrivacyAccepted    = "privacy_accepted";

    // UI language: "system" (default, follows OS) / "zh-CN" / "en"
    public const string Language           = "language";

    // Multimodal / Vision
    public const string MultimodalEnabled    = "multimodal_enabled";
    public const string VisionEnabled        = "vision_enabled";
    public const string VisionModelId        = "vision_model_id";
    // Vision-specific provider (separate from main LLM profile, for cross-provider routing)
    public const string VisionProviderBaseUrl = "vision_provider_base_url";
    public const string VisionProviderApiKey  = "vision_provider_api_key";
    public const string VisionProviderModelId = "vision_provider_model_id";

    // Auto-learning (ASR variant learning)
    public const string AutoLearningEnabled    = "auto_learning_enabled";
    public const string AutoLearningMinMatches = "auto_learning_min_matches";
}
