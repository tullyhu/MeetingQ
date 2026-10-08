using MeetingQ.Models;
using System.Text.Json;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Persists the list of user-configured LLM profiles to SecureStorage (DPAPI-encrypted JSON).
/// </summary>
public static class LlmProfileStore
{
    public static List<LlmProfile> Load()
    {
        var json = SecureStorage.Load(SecureStorageKeys.LlmProfiles);
        if (string.IsNullOrEmpty(json)) return new();
        try { return JsonSerializer.Deserialize<List<LlmProfile>>(json) ?? new(); }
        catch { return new(); }
    }

    public static void Save(IEnumerable<LlmProfile> profiles)
    {
        var json = JsonSerializer.Serialize(profiles.ToList());
        SecureStorage.Save(SecureStorageKeys.LlmProfiles, json);
    }

    public static LlmProfile? GetActive()
        => Load().FirstOrDefault(p => p.IsActive);
}
