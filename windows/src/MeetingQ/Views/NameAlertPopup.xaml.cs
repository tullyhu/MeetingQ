using MeetingQ.Infrastructure;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace MeetingQ.Views;

public partial class NameAlertPopup : Window
{
    private DispatcherTimer? _elapsedTimer;
    private DateTime         _detectedAt;

    public bool IsPinned { get; private set; }

    public NameAlertPopup()
    {
        InitializeComponent();
    }

    public void ShowAlert(string originalText, string[] questions,
                          DateTime detectedAt, string[] contextLines, string? screenshotPath)
    {
        _detectedAt = detectedAt;

        // Reset pin state for each new alert
        IsPinned          = false;
        PinButton.Opacity = 0.5;
        PinButton.ToolTip = LocalizationManager.Get("NameAlertPinTooltipFull");

        OriginalTextBlock.Text = originalText;

        // Screenshot thumbnail
        if (!string.IsNullOrEmpty(screenshotPath) && System.IO.File.Exists(screenshotPath))
        {
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption  = BitmapCacheOption.OnLoad;
                bmp.UriSource    = new Uri(screenshotPath);
                bmp.EndInit();
                bmp.Freeze();
                ScreenshotImage.Source     = bmp;
                ScreenshotPanel.Visibility = Visibility.Visible;
            }
            catch { ScreenshotPanel.Visibility = Visibility.Collapsed; }
        }
        else
        {
            ScreenshotPanel.Visibility = Visibility.Collapsed;
        }

        // Number the questions ❶ ❷ ❸ …
        QuestionsItemsControl.ItemsSource = questions
            .Select((q, i) => $"{NumberedCircle(i)}  {q}")
            .ToArray();

        // Context section: show if there's anything to display
        if (contextLines.Length > 0)
        {
            ContextItemsControl.ItemsSource = contextLines;
            ContextPanel.Visibility = Visibility.Visible;
        }
        else
        {
            ContextPanel.Visibility = Visibility.Collapsed;
        }

        // Restart elapsed counter
        _elapsedTimer?.Stop();
        _elapsedTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _elapsedTimer.Tick += (_, _) => UpdateElapsed();
        _elapsedTimer.Start();
        UpdateElapsed();

        Show();
        Activate();
        // Reposition after layout so ActualHeight is correct (SizeToContent="Height")
        Dispatcher.BeginInvoke(PositionBottomRight, DispatcherPriority.Loaded);
    }

    private void UpdateElapsed()
    {
        var elapsed = DateTime.Now - _detectedAt;
        var s = (int)elapsed.TotalSeconds;
        ElapsedText.Text = s < 1
            ? LocalizationManager.Get("NameAlertJustNow")
            : s < 60
                ? LocalizationManager.Format("NameAlertSecondsAgo", s)
                : LocalizationManager.Format("NameAlertMinutesAgo", s / 60, s % 60);
    }

    private static string NumberedCircle(int index) => index switch
    {
        0 => "❶", 1 => "❷", 2 => "❸", 3 => "❹", 4 => "❺",
        5 => "❻", 6 => "❼", 7 => "❽", 8 => "❾", _ => $"{index + 1}."
    };

    private void PositionBottomRight()
    {
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right  - Width  - 16;
        Top  = workArea.Bottom - ActualHeight - 16;
        if (Top < workArea.Top) Top = workArea.Top + 16;
    }

    private void PinButton_Click(object sender, RoutedEventArgs e)
    {
        IsPinned         = !IsPinned;
        PinButton.Opacity = IsPinned ? 1.0 : 0.5;
        PinButton.ToolTip = IsPinned
            ? LocalizationManager.Get("NameAlertPinnedTooltip")
            : LocalizationManager.Get("NameAlertPinTooltipFull");
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && !IsPinned)
        {
            _elapsedTimer?.Stop();
            Hide();
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        IsPinned = false;
        _elapsedTimer?.Stop();
        Hide();
    }

    private void AcknowledgeButton_Click(object sender, RoutedEventArgs e)
    {
        _elapsedTimer?.Stop();
        Hide();
    }

    private void ScreenshotThumbnail_Click(object sender, MouseButtonEventArgs e)
    {
        if (ScreenshotImage.Source is not BitmapSource bmp) return;

        var lightbox = new Window
        {
            WindowStyle        = WindowStyle.None,
            ResizeMode         = ResizeMode.NoResize,
            WindowState        = WindowState.Maximized,
            Background         = new SolidColorBrush(Color.FromArgb(220, 0, 0, 0)),
            AllowsTransparency = true,
            Topmost            = true,
            ShowInTaskbar      = false,
            Cursor             = Cursors.Hand,
            Title              = LocalizationManager.Get("ScreenshotPreviewTitle")
        };

        var img = new Image
        {
            Source              = bmp,
            Stretch             = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment   = VerticalAlignment.Center
        };

        lightbox.Content       = img;
        lightbox.MouseDown    += (_, _) => lightbox.Close();
        lightbox.KeyDown      += (_, args) => { if (args.Key == Key.Escape) lightbox.Close(); };
        lightbox.ShowDialog();
    }
}
