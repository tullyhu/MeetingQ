using MeetingQ.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Animation;

namespace MeetingQ.Views;

public partial class FloatingWindow : Window
{
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);
    private const int GWL_EXSTYLE     = -20;
    private const int WS_EX_APPWINDOW  = 0x00040000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int MaxUnpinnedAlerts = 3;
    private readonly IServiceProvider _services;
    private SettingsWindow?  _settingsWindow;
    private HistoryWindow?   _historyWindow;
    private NameAlertPopup?  _nameAlertPopup;
    private readonly List<NameAlertPopup> _openAlertPopups = new();
    private bool _userScrolledUp;
    private bool _isExiting;

    public FloatingWindow(FloatingWindowViewModel viewModel, IServiceProvider services)
    {
        InitializeComponent();
        DataContext = viewModel;
        _services   = services;

        viewModel.NameDetected += OnNameDetected;
        viewModel.ConfigurationRequired += () => OpenSettings_Click(this, new System.Windows.RoutedEventArgs());
        viewModel.TopicChanged += OnTopicChanged;
        viewModel.WindowSelectionRequired += OnWindowSelectionRequired;

        // Auto-scroll transcript panel when new text arrives (unless the user scrolled up)
        viewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(FloatingWindowViewModel.LatestTranscript))
                Dispatcher.BeginInvoke(() =>
                {
                    if (!_userScrolledUp)
                        TranscriptScroller?.ScrollToEnd();
                });
        };
    }

    private void TranscriptScroller_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        // Content growth (ExtentHeightChange > 0) is the auto-scroll path, not user input.
        if (e.ExtentHeightChange != 0) return;
        _userScrolledUp = e.VerticalOffset < e.ExtentHeight - e.ViewportHeight - 20;
    }

    private void OnWindowSelectionRequired()
    {
        Dispatcher.BeginInvoke(() =>
        {
            WindowPickerCombo.Focus();
            WindowPickerCombo.IsDropDownOpen = true;
        });
    }

    private void WindowPickerCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (WindowPickerCombo.SelectedItem is string title
            && DataContext is FloatingWindowViewModel vm)
            vm.OnWindowExplicitlySelected(title);
    }

    private void OnTopicChanged()
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (Resources["TopicFlash"] is not Storyboard sb) return;
            sb.Stop(TopicHighlight);
            sb.Begin(TopicHighlight, true);
        });
    }

    private void OnNameDetected(string originalText, string[] questions,
                                DateTime detectedAt, string[] contextLines, string? screenshotPath)
    {
        // If the current popup is pinned by the user, open a fresh one alongside it.
        // Otherwise reuse the existing instance (or create one if not loaded).
        if (_nameAlertPopup is null || !_nameAlertPopup.IsLoaded || _nameAlertPopup.IsPinned)
            _nameAlertPopup = _services.GetRequiredService<NameAlertPopup>();

        _nameAlertPopup.ShowAlert(originalText, questions, detectedAt, contextLines, screenshotPath);

        _openAlertPopups.RemoveAll(p => !p.IsLoaded);
        if (!_openAlertPopups.Contains(_nameAlertPopup))
            _openAlertPopups.Add(_nameAlertPopup);

        // Cap simultaneous unpinned popups — close the oldest beyond the limit
        var unpinned = _openAlertPopups.Where(p => !p.IsPinned).ToList();
        while (unpinned.Count > MaxUnpinnedAlerts)
        {
            var oldest = unpinned[0];
            unpinned.RemoveAt(0);
            _openAlertPopups.Remove(oldest);
            oldest.Close();
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        // WindowStyle=None + AllowsTransparency=True strips WS_EX_APPWINDOW, hiding the window
        // from the taskbar. Force it back so the app button always appears.
        var hwnd    = new WindowInteropHelper(this).Handle;
        var exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, (exStyle & ~WS_EX_TOOLWINDOW) | WS_EX_APPWINDOW);
    }

    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
            DragMove();
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        if (DataContext is FloatingWindowViewModel vm)
            vm.CancelPendingStart();
        MinimizeToTray();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        MinimizeToTray();
    }

    /// <summary>Marks the window as closing for real (app exit) instead of hiding to tray.</summary>
    public void MarkExiting() => _isExiting = true;

    protected override void OnClosing(CancelEventArgs e)
    {
        // Intercept any close attempt (Alt+F4, etc.).
        // During actual app shutdown let the close proceed; otherwise hide to tray.
        if (!_isExiting && !Application.Current.Dispatcher.HasShutdownStarted)
        {
            e.Cancel = true;
            MinimizeToTray();
        }
        base.OnClosing(e);
    }

    private void MinimizeToTray()
    {
        ShowInTaskbar = false;
        Hide();
    }

    public void RestoreFromTray()
    {
        ShowInTaskbar = true;
        Show();
        Activate();
        if (WindowState == System.Windows.WindowState.Minimized)
            WindowState = System.Windows.WindowState.Normal;
    }

    private void OpenSettings_Click(object sender, RoutedEventArgs e)
    {
        if (_settingsWindow is { IsVisible: true })
        {
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = _services.GetRequiredService<SettingsWindow>();
        _settingsWindow.Owner = this;
        _settingsWindow.Show();
    }

    private void OpenHistory_Click(object sender, RoutedEventArgs e)
    {
        if (_historyWindow is { IsVisible: true })
        {
            _historyWindow.Activate();
            return;
        }

        _historyWindow = _services.GetRequiredService<HistoryWindow>();
        _historyWindow.Owner = this;
        _historyWindow.Show();
    }
}
