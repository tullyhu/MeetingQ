using System.Windows.Media.Imaging;

namespace MeetingQ.ViewModels;

public class ScreenshotItem
{
    public string        FilePath  { get; }
    public DateTime      Timestamp { get; }
    public string        TimeLabel => Timestamp.ToString("HH:mm:ss");
    public string?       AiSummary { get; set; }
    public string?       AnalysisStatus { get; set; }
    public string?       ActiveSpeakerName { get; set; }
    public BitmapSource? Thumbnail { get; private set; }

    public ScreenshotItem(string filePath, DateTime timestamp)
    {
        FilePath  = filePath;
        Timestamp = timestamp;
    }

    /// <summary>Loads a small thumbnail. Safe to call on any thread; result is frozen.</summary>
    public void LoadThumbnail()
    {
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.UriSource        = new Uri(FilePath);
            bi.DecodePixelWidth = 120;
            bi.CacheOption      = BitmapCacheOption.OnLoad;
            bi.EndInit();
            bi.Freeze();
            Thumbnail = bi;
        }
        catch { /* ignore — thumbnail stays null */ }
    }
}
