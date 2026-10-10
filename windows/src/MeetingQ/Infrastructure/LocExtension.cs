using System.Windows;
using System.Windows.Data;
using System.Windows.Markup;

namespace MeetingQ.Infrastructure;

/// <summary>
/// Markup extension for localized strings with live language switching.
/// Usage in XAML:  xmlns:local="clr-namespace:MeetingQ.Infrastructure"
///                 <Button Content="{local:Loc Save}"/>
///                 <TextBlock Text="{local:Loc Key=Greeting}"/>
/// Binds to LocalizationManager.Instance[key]; all instances refresh when the language changes.
/// </summary>
[MarkupExtensionReturnType(typeof(BindingExpression))]
public sealed class LocExtension : MarkupExtension
{
    public string? Key { get; set; }

    public LocExtension() { }

    public LocExtension(string key) => Key = key;

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        if (string.IsNullOrEmpty(Key))
            return string.Empty;

        var binding = new Binding($"[{Key}]")
        {
            Source = LocalizationManager.Instance,
            Mode = BindingMode.OneWay,
        };
        return binding.ProvideValue(serviceProvider);
    }
}
