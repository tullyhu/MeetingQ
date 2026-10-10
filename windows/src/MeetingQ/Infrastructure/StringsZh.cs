namespace MeetingQ.Infrastructure;

/// <summary>
/// Chinese (default) UI string table. Keys are PascalCase identifiers.
/// Table is composed from per-area partial files:
///   StringsZh.Views.cs  (ViewsEntries)      — XAML windows/popups + code-behind
///   StringsZh.ViewModels.cs (ViewModelEntries) — status labels, dialog texts in VMs
///   StringsZh.Services.cs (ServiceEntries)  — services, prompts, tray, App.xaml.cs
/// StringsEn mirrors every key.
/// </summary>
internal static partial class StringsZh
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
