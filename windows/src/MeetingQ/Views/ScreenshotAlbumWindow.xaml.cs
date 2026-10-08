using MeetingQ.ViewModels;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Input;

namespace MeetingQ.Views;

public partial class ScreenshotAlbumWindow : Window
{
    private readonly ScreenshotAlbumViewModel _vm;

    public ScreenshotAlbumWindow(ScreenshotAlbumViewModel viewModel)
    {
        InitializeComponent();
        _vm         = viewModel;
        DataContext = viewModel;

        // Auto-scroll thumbnail strip to show the latest screenshot when added
        _vm.Screenshots.CollectionChanged += OnScreenshotsChanged;
    }

    private void OnScreenshotsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems is { Count: > 0 })
            ThumbnailList.ScrollIntoView(e.NewItems[e.NewItems.Count - 1]);
    }

    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
            DragMove();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Hide();

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!Application.Current.Dispatcher.HasShutdownStarted)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }
}
