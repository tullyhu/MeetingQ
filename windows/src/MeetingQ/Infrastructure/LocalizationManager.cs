using System.ComponentModel;
using System.Globalization;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Central UI localization service. Usage:
///   XAML:  Text="{local:Loc Save}"
///   Code:  LocalizationManager.Instance["Save"]  /  LocalizationManager.Get("Save")
/// Language is persisted via StorageConfig; default follows the OS display language.
/// When the language changes, PropertyChanged("Item[]") refreshes every {local:Loc} binding live.
/// String tables live in Localization/StringsZh.cs and StringsEn.cs.
/// </summary>
public sealed class LocalizationManager : INotifyPropertyChanged
{
    public static LocalizationManager Instance { get; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised after the effective language changes (for code that rebuilds UI, e.g. tray menu).</summary>
    public event EventHandler? LanguageChanged;

    private AppLanguage _preference = AppLanguage.System;
    private bool _isEnglish;

    private LocalizationManager()
    {
        ApplyEffectiveLanguage();
    }

    /// <summary>The user's configured preference (System / Chinese / English).</summary>
    public AppLanguage Preference
    {
        get => _preference;
        set
        {
            if (_preference == value) return;
            _preference = value;
            ApplyEffectiveLanguage();
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Preference)));
            LanguageChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>True when the effective UI language is English.</summary>
    public bool IsEnglish
    {
        get => _isEnglish;
        private set
        {
            if (_isEnglish == value) return;
            _isEnglish = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsEnglish)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CurrentCulture)));
            // Refresh all {local:Loc} indexer bindings.
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
        }
    }

    /// <summary>Effective culture ("zh-CN" or "en").</summary>
    public string CurrentCulture => IsEnglish ? "en" : "zh-CN";

    /// <summary>Indexer used by {local:Loc} bindings. Falls back to Chinese, then to the key itself.</summary>
    public string this[string key]
    {
        get
        {
            var table = IsEnglish ? StringsEn.Table : StringsZh.Table;
            if (table.TryGetValue(key, out var v)) return v;
            if (StringsZh.Table.TryGetValue(key, out v)) return v;
            return key;
        }
    }

    /// <summary>Lookup helper for code.</summary>
    public static string Get(string key) => Instance[key];

    /// <summary>Lookup + format helper for code.</summary>
    public static string Format(string key, params object?[] args)
        => string.Format(CultureInfo.InvariantCulture, Instance[key], args);

    /// <summary>Restore persisted preference at startup.</summary>
    public void LoadPreference(AppLanguage preference) => Preference = preference;

    private void ApplyEffectiveLanguage()
    {
        IsEnglish = _preference switch
        {
            AppLanguage.English => true,
            AppLanguage.Chinese => false,
            _ => !CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase),
        };
    }
}
