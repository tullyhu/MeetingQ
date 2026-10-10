using MeetingQ.Infrastructure;
using MeetingQ.ViewModels;
using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace MeetingQ.Views;

public partial class SettingsWindow : Window
{
    private readonly SettingsViewModel _vm;

    public SettingsWindow(SettingsViewModel viewModel)
    {
        InitializeComponent();
        DataContext = viewModel;
        _vm = viewModel;
        _vm.RestartRequired               += OnRestartRequired;
        _vm.BrowseDataDirRequested        += OnBrowseDataDir;
        _vm.ConfirmClearRequested         += OnConfirmClear;
        _vm.ConfirmDataClearRequested     += OnConfirmDataClear;
        _vm.ExportConfigPathRequested     += OnExportConfigPath;
        _vm.ImportConfigPathRequested     += OnImportConfigPath;
        _vm.ConfirmConfigOverwriteRequested += OnConfirmConfigOverwrite;
        _vm.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(SettingsViewModel.SelectedProfile))
                ProfileApiKeyBox.Password = _vm.SelectedProfile?.ApiKey ?? string.Empty;
        };
    }

    // ── Restart ───────────────────────────────────────────────────────────────

    private void OnRestartRequired()
    {
        var result = MessageBox.Show(
            LocalizationManager.Get("RestartBody"),
            LocalizationManager.Get("RestartTitle"),
            MessageBoxButton.OKCancel,
            MessageBoxImage.Information);

        if (result == MessageBoxResult.OK)
        {
            var exe = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
            if (exe is not null)
            {
                Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
                Application.Current.Shutdown();
            }
            else
            {
                MessageBox.Show(
                    LocalizationManager.Get("ManualRestartBody"),
                    LocalizationManager.Get("ManualRestartTitle"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                Close();
            }
        }
        else
        {
            // User declined restart — close settings anyway; changes are saved and take effect next launch
            Close();
        }
    }

    // ── Data directory ────────────────────────────────────────────────────────

    private string? OnBrowseDataDir(string currentPath)
    {
        var dlg = new OpenFolderDialog
        {
            Title          = LocalizationManager.Get("BrowseDataDirTitle"),
            InitialDirectory = currentPath,
            Multiselect    = false
        };
        return dlg.ShowDialog() == true ? dlg.FolderName : null;
    }

    // ── Config import / export / clear ────────────────────────────────────────

    private bool OnConfirmClear()
    {
        var result = MessageBox.Show(
            LocalizationManager.Get("ClearConfigBody"),
            LocalizationManager.Get("ClearConfigTitle"),
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning);
        return result == MessageBoxResult.OK;
    }

    private bool OnConfirmDataClear(string message)
    {
        var result = MessageBox.Show(
            message, LocalizationManager.Get("ClearDataTitle"),
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning);
        return result == MessageBoxResult.OK;
    }

    // ── API Key PasswordBox sync (Password is not bindable) ───────────────────

    private void ProfileApiKeyBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_vm.SelectedProfile is not null)
            _vm.SelectedProfile.ApiKey = ProfileApiKeyBox.Password;
    }

    private void VisionApiKeyBox_PasswordChanged(object sender, RoutedEventArgs e)
        => _vm.VisionProviderApiKey = VisionApiKeyBox.Password;

    private void Window_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Escape)
            Close();
    }

    // ── Config import / export ──────────────────────────────────────────────

    private string? OnExportConfigPath(string defaultName)
    {
        var dlg = new SaveFileDialog
        {
            Title      = LocalizationManager.Get("ExportConfigTitle"),
            FileName   = defaultName,
            DefaultExt = ".json",
            Filter     = string.Join('|', LocalizationManager.Get("FileFilterJson"),
                         LocalizationManager.Get("FileFilterAll"))
        };
        return dlg.ShowDialog(this) == true ? dlg.FileName : null;
    }

    private string? OnImportConfigPath(string defaultName)
    {
        var dlg = new OpenFileDialog
        {
            Title      = LocalizationManager.Get("ImportConfigTitle"),
            FileName   = defaultName,
            DefaultExt = ".json",
            Filter     = string.Join('|', LocalizationManager.Get("FileFilterJson"),
                         LocalizationManager.Get("FileFilterAll")),
            Multiselect = false
        };
        return dlg.ShowDialog(this) == true ? dlg.FileName : null;
    }

    private bool OnConfirmConfigOverwrite(string message)
    {
        var result = MessageBox.Show(
            message, LocalizationManager.Get("ImportConfirmTitle"),
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning);
        return result == MessageBoxResult.OK;
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        _vm.RestartRequired               -= OnRestartRequired;
        _vm.BrowseDataDirRequested        -= OnBrowseDataDir;
        _vm.ConfirmClearRequested         -= OnConfirmClear;
        _vm.ConfirmDataClearRequested     -= OnConfirmDataClear;
        _vm.ExportConfigPathRequested     -= OnExportConfigPath;
        _vm.ImportConfigPathRequested     -= OnImportConfigPath;
        _vm.ConfirmConfigOverwriteRequested -= OnConfirmConfigOverwrite;
    }

    // ── Log collection ────────────────────────────────────────────────────────

    private async void CollectLogsButton_Click(object sender, RoutedEventArgs e)
    {
        var btn = (Button)sender;
        btn.IsEnabled = false;
        btn.Content   = LocalizationManager.Get("CollectingLogs");
        try
        {
            var reportDir  = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "MeetingQ");
            System.IO.Directory.CreateDirectory(reportDir);
            var reportPath = System.IO.Path.Combine(reportDir,
                $"DiagnosticReport_{DateTime.Now:yyyyMMdd_HHmmss}.txt");

            var sb = new System.Text.StringBuilder();
            sb.AppendLine("╔══════════════════════════════════╗");
            sb.AppendLine($"║   {LocalizationManager.Get("DiagReportTitle")}           ║");
            sb.AppendLine("╚══════════════════════════════════╝");
            sb.AppendLine($"{LocalizationManager.Get("DiagGeneratedAt")}    : {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
            sb.AppendLine($"{LocalizationManager.Get("DiagOs")}    : {Environment.OSVersion}");
            sb.AppendLine($"{LocalizationManager.Get("DiagRuntime")} : {Environment.Version}");
            sb.AppendLine($"{LocalizationManager.Get("DiagArch")}    : {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}");
            sb.AppendLine($"{LocalizationManager.Get("DiagMemory")}    : {GC.GetTotalMemory(false) / 1024 / 1024} MB");
            sb.AppendLine();

            // Append the two most recent per-startup log files (latest 1000 lines each,
            // read from the tail so huge logs are never loaded fully into memory)
            var recentLogs = System.IO.Directory
                .GetFiles(AppLog.LogDirectory, "meetingq-*.log")
                .OrderByDescending(f => f)
                .Take(2)
                .ToList();
            foreach (var logFile in recentLogs)
            {
                var logName = System.IO.Path.GetFileNameWithoutExtension(logFile);
                sb.AppendLine($"────────────── {LocalizationManager.Format("DiagLogSection", logName)} ──────────────");
                foreach (var line in await ReadLogTailAsync(logFile, 1000))
                    sb.AppendLine(line);
                sb.AppendLine();
            }

            await System.IO.File.WriteAllTextAsync(reportPath, sb.ToString(), System.Text.Encoding.UTF8);

            Clipboard.SetText(reportPath);
            Process.Start(new ProcessStartInfo
            {
                FileName        = "explorer.exe",
                Arguments       = $"/select,\"{reportPath}\"",
                UseShellExecute = true
            });
            btn.Content = LocalizationManager.Get("LogsSaved");
        }
        catch (Exception ex)
        {
            btn.Content = LocalizationManager.Get("LogsFailed");
            MessageBox.Show(ex.Message, LocalizationManager.Get("LogsFailedTitle"), MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            btn.IsEnabled = true;
            await Task.Delay(2000);
            btn.Content = LocalizationManager.Get("SettingsCollectLogs");
        }
    }

    // ── Log tail reader ───────────────────────────────────────────────────────

    private static async Task<List<string>> ReadLogTailAsync(string path, int maxLines)
    {
        const int TailBytes = 256 * 1024;
        using var fs = new System.IO.FileStream(path,
            System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite);

        var start = Math.Max(0, fs.Length - TailBytes);
        fs.Seek(start, System.IO.SeekOrigin.Begin);

        using var reader = new System.IO.StreamReader(fs, System.Text.Encoding.UTF8);
        var chunk = await reader.ReadToEndAsync();

        var lines = chunk.Split('\n');
        // If we didn't start at the file beginning, the first line is likely partial — drop it
        var startIndex = start > 0 ? 1 : 0;
        return lines.Skip(startIndex).TakeLast(maxLines).ToList();
    }

    protected override async void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        ProfileApiKeyBox.Password = _vm.SelectedProfile?.ApiKey ?? string.Empty;
        VisionApiKeyBox.Password  = _vm.VisionProviderApiKey;
        await _vm.LoadStatsAsync();
    }
}
