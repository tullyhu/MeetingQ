namespace MeetingQ.Infrastructure;

/// <summary>
/// English UI string table. Mirrors every key in StringsZh.
/// Missing keys fall back to Chinese at lookup time, but the goal is full coverage.
/// </summary>
internal static partial class StringsEn
{
    private static IReadOnlyDictionary<string, string>? _table;

    internal static IReadOnlyDictionary<string, string> Table => _table ??= Build();

    private static IReadOnlyDictionary<string, string> Build()
    {
        var d = new Dictionary<string, string>();
        foreach (var kv in ViewsEntries) d[kv.Key] = kv.Value;
        foreach (var kv in ViewModelEntries) d[kv.Key] = kv.Value;
        foreach (var kv in ServiceEntries) d[kv.Key] = kv.Value;
        return d;
    }
}
