using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.Extensions.Logging;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media.Imaging;

namespace MeetingQ.ViewModels;

public partial class ScreenshotAlbumViewModel : ObservableObject
{
    private readonly ILogger<ScreenshotAlbumViewModel> _logger;

    public ObservableCollection<ScreenshotItem> Screenshots { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SelectedImage))]
    [NotifyPropertyChangedFor(nameof(SelectedTimestamp))]
    [NotifyPropertyChangedFor(nameof(HasSelected))]
    private ScreenshotItem? _selectedScreenshot;

    [ObservableProperty] private BitmapSource? _selectedImage;

    public string SelectedTimestamp => SelectedScreenshot?.Timestamp.ToString("yyyy-MM-dd  HH:mm:ss") ?? string.Empty;
    public bool   HasSelected       => SelectedScreenshot is not null;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasScreenshots))]
    private int _screenshotCount;

    public bool   HasScreenshots => ScreenshotCount > 0;
    public string CountLabel     => ScreenshotCount == 0 ? "暂无截图" : $"{ScreenshotCount} 张";

    public ScreenshotAlbumViewModel(ILogger<ScreenshotAlbumViewModel> logger)
    {
        _logger = logger;
    }

    // ── Called by FloatingWindowViewModel when a screenshot is captured ──

    public ScreenshotItem AddScreenshot(string filePath, DateTime timestamp, string? aiSummary = null)
    {
        var item = new ScreenshotItem(filePath, timestamp) { AiSummary = aiSummary };
        _ = Task.Run(() =>
        {
            item.LoadThumbnail();
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                Screenshots.Add(item);
                ScreenshotCount = Screenshots.Count;
                OnPropertyChanged(nameof(CountLabel));
                SelectedScreenshot = item;
            });
        });
        return item;
    }

    public void Clear()
    {
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            Screenshots.Clear();
            ScreenshotCount    = 0;
            SelectedScreenshot = null;
            SelectedImage      = null;
            OnPropertyChanged(nameof(CountLabel));
        });
    }

    // ── Selection change → load full image ───────────────────────────────

    private int _loadSeq;

    partial void OnSelectedScreenshotChanged(ScreenshotItem? value)
    {
        SelectedImage = null;
        if (value is null) return;

        var seq = System.Threading.Interlocked.Increment(ref _loadSeq);
        _ = Task.Run(() =>
        {
            try
            {
                var bi = new BitmapImage();
                bi.BeginInit();
                bi.UriSource   = new Uri(value.FilePath);
                bi.CacheOption = BitmapCacheOption.OnLoad;
                bi.EndInit();
                bi.Freeze();
                Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    // A newer selection superseded this slow load — discard it
                    if (seq != System.Threading.Interlocked.CompareExchange(ref _loadSeq, 0, 0))
                        return;
                    SelectedImage = bi;
                });
            }
            catch { }
        });
    }
}
