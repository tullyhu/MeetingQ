using MeetingQ.ViewModels;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace MeetingQ.Views;

public partial class HistoryWindow : Window
{
    private readonly HistoryViewModel _vm;

    public HistoryWindow(HistoryViewModel viewModel)
    {
        InitializeComponent();
        _vm         = viewModel;
        DataContext = viewModel;

        _vm.ExportPathRequested            += OnExportPathRequested;
        _vm.ExportTranscriptPathRequested += OnExportTranscriptPathRequested;
        _vm.ExportHtmlPathRequested       += OnExportHtmlPathRequested;
        _vm.ConfirmDeleteRequested        += OnConfirmDelete;
        _vm.EditSpeakersRequested         += OnEditSpeakers;
    }

    protected override async void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        await _vm.LoadAsync();
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        _vm.ExportPathRequested            -= OnExportPathRequested;
        _vm.ExportTranscriptPathRequested  -= OnExportTranscriptPathRequested;
        _vm.ExportHtmlPathRequested        -= OnExportHtmlPathRequested;
        _vm.ConfirmDeleteRequested         -= OnConfirmDelete;
        _vm.EditSpeakersRequested          -= OnEditSpeakers;
    }

    private Task OnEditSpeakers(SessionItem session)
    {
        var speakers = HistoryViewModel.GetDistinctSpeakers(session);
        var dlg = new SpeakerRenameDialog(speakers,
            (oldName, newName) => _vm.RenameSpeakerAsync(session, oldName, newName))
        {
            Owner = this
        };
        dlg.ShowDialog();
        return Task.CompletedTask;
    }

    private bool OnConfirmDelete(int sessionId)
    {
        var result = MessageBox.Show(
            "确定要删除此会议记录及其所有转录、截图、决策和行动项吗？\n\n此操作不可撤销。",
            "删除确认", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        return result == MessageBoxResult.OK;
    }

    private string? OnExportPathRequested(string defaultName)
    {
        var dlg = new SaveFileDialog
        {
            Title            = "导出会议纪要",
            FileName         = defaultName,
            DefaultExt       = ".md",
            Filter           = "Markdown 文件 (*.md)|*.md|文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*"
        };
        return dlg.ShowDialog(this) == true ? dlg.FileName : null;
    }

    private string? OnExportHtmlPathRequested(string defaultName)
    {
        var dlg = new SaveFileDialog
        {
            Title            = "导出会议纪要 (HTML)",
            FileName         = defaultName,
            DefaultExt       = ".html",
            Filter           = "HTML 文件 (*.html)|*.html|所有文件 (*.*)|*.*"
        };
        return dlg.ShowDialog(this) == true ? dlg.FileName : null;
    }

    private string? OnExportTranscriptPathRequested(string defaultName)
    {
        var dlg = new SaveFileDialog
        {
            Title            = "导出转写记录",
            FileName         = defaultName,
            DefaultExt       = ".txt",
            Filter           = "文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*"
        };
        return dlg.ShowDialog(this) == true ? dlg.FileName : null;
    }

    private void Screenshot_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border border) return;
        if (border.Child is not Image img) return;

        BitmapSource? src = null;
        if (border.DataContext is ScreenshotItem si)
        {
            if (!System.IO.File.Exists(si.FilePath))
            {
                MessageBox.Show(this, "截图文件不存在，可能已被删除。", "图片无法加载",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.UriSource   = new Uri(si.FilePath);
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.EndInit();
                bmp.Freeze();
                src = bmp;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"图片无法加载：{ex.Message}", "图片无法加载",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
        }
        else if (img.Source is BitmapSource bs)
        {
            src = bs;
        }
        if (src is null) return;

        var lightbox = new Window
        {
            Owner             = this,
            WindowStyle       = WindowStyle.None,
            WindowState       = WindowState.Maximized,
            AllowsTransparency = true,
            Background        = new SolidColorBrush(Color.FromArgb(220, 0, 0, 0)),
            Topmost           = true,
            Cursor            = Cursors.Hand,
            Content           = new Image { Source = src, Stretch = Stretch.Uniform }
        };
        lightbox.MouseDown += (_, _) => lightbox.Close();
        lightbox.KeyDown   += (_, args) => { if (args.Key == Key.Escape) lightbox.Close(); };
        lightbox.ShowDialog();
    }
}
