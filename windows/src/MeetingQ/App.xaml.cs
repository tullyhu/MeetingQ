using MeetingQ.Data;
using MeetingQ.Infrastructure;
using MeetingQ.Services;
using MeetingQ.Services.Interfaces;
using MeetingQ.ViewModels;
using MeetingQ.Views;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;

namespace MeetingQ;

public partial class App : Application
{
    private IHost?              _host;

    private SingleInstanceGuard? _singleInstanceGuard;
    private NativeTrayIcon?     _trayIcon;

#if DEBUG
    [DllImport("kernel32.dll")]
    private static extern bool AllocConsole();
#endif

    protected override async void OnStartup(StartupEventArgs e)
    {
        // Catch any unhandled exception and show it in a MessageBox before the process dies.
        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
            MessageBox.Show(ex.ExceptionObject?.ToString(), LocalizationManager.Get("AppStartupErrorTitle"),
                MessageBoxButton.OK, MessageBoxImage.Error);

        DispatcherUnhandledException += (_, ex) =>
        {
            AppLog.Error("App", "Dispatcher 未处理异常", ex.Exception);
            MessageBox.Show(ex.Exception?.ToString(), LocalizationManager.Get("AppRuntimeErrorTitle"),
                MessageBoxButton.OK, MessageBoxImage.Error);
            ex.Handled = true;
        };

        base.OnStartup(e);

        // Initialize file logger immediately — before everything else so no log is lost.
        AppLog.Initialize();

        // Restore the persisted UI-language preference as early as possible so the
        // error dialogs above/below show the right language even during startup crashes.
        try
        {
            LocalizationManager.Instance.LoadPreference(
                SecureStorage.Load(SecureStorageKeys.Language) switch
                {
                    "zh-CN" => AppLanguage.Chinese,
                    "en"    => AppLanguage.English,
                    _       => AppLanguage.System,
                });
        }
        catch { }

        // Tray app: only exit when Shutdown() is explicitly called (e.g. tray menu "退出").
        // OnLastWindowClose (the default) would exit when all windows are closed, but we
        // hide the main window to tray, so we never want implicit shutdown.
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

#if DEBUG
        AllocConsole();
#endif

        try
        {
        // ── 1. Single-instance check ──────────────────────────────────────
        _singleInstanceGuard = new SingleInstanceGuard();
        if (_singleInstanceGuard.IsAlreadyRunning())
        {
            _singleInstanceGuard.BringExistingToFront();
            _singleInstanceGuard.Dispose();
            Shutdown();
            return;
        }

        // ── 2. Build Generic Host with DI ─────────────────────────────────
        _host = Host.CreateDefaultBuilder()
            .ConfigureLogging(logging =>
            {
                logging.ClearProviders();
                logging.AddConsole();
                logging.AddDebug();
#if DEBUG
                logging.SetMinimumLevel(LogLevel.Debug);
#else
                logging.SetMinimumLevel(LogLevel.Information);
#endif
            })
            .ConfigureServices((_, services) =>
            {
                // Database — factory so ViewModels create short-lived contexts per operation
                var dbPath = AppDbContext.GetDatabasePath();
                services.AddDbContextFactory<AppDbContext>(options =>
                    options.UseSqlite($"Data Source={dbPath}"));

                // Services
                services.AddSingleton<IAudioCaptureService, AudioCaptureService>();
                // ASR: fully local sherpa-onnx (streaming Paraformer + speaker clustering)
                services.AddSingleton<IAsrService, SherpaOnnxAsrService>();
                // LLM: single configurable service (OpenAI-compatible, profile-driven)
                services.AddSingleton<ILlmService,           ConfigurableLlmService>();
                services.AddSingleton<IScreenCaptureService, ScreenCaptureService>();
                services.AddSingleton<INameDetectionService, NameDetectionService>();
                services.AddSingleton<IVisionService, VisionService>();
                services.AddSingleton<LocalOcrService>();

                // ViewModels
                services.AddSingleton<FloatingWindowViewModel>();
                services.AddTransient<SettingsViewModel>();
                services.AddSingleton<ScreenshotAlbumViewModel>();
                services.AddTransient<HistoryViewModel>();

                // Views
                services.AddSingleton<FloatingWindow>();
                services.AddTransient<SettingsWindow>();
                services.AddTransient<NameAlertPopup>();
                services.AddSingleton<QuickSummaryPopup>();
                services.AddSingleton<ScreenshotAlbumWindow>();
                services.AddTransient<HistoryWindow>();
            })
            .Build();

        await _host.StartAsync();

        // ── 3. Apply pending EF migrations (creates DB on first run) ──────
        using (var scope = _host.Services.CreateScope())
        {
            var dbFactory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<AppDbContext>>();
            await using var db = await dbFactory.CreateDbContextAsync();

            // Back up the DB file before touching it — if migration fails the user
            // still has a recoverable copy instead of a half-migrated file.
            var dbFile = AppDbContext.GetDatabasePath();
            string? backupPath = null;
            try
            {
                if (File.Exists(dbFile))
                {
                    backupPath = $"{dbFile}.bak-{DateTime.Now:yyyyMMdd-HHmmss}";
                    File.Copy(dbFile, backupPath);
                }
            }
            catch (Exception ex)
            {
                AppLog.Warn("App", $"数据库备份失败（继续迁移）: {ex.Message}");
                backupPath = null;
            }

            try
            {
                await db.Database.MigrateAsync();
            }
            catch (Exception ex) when (IsLegacySchemaError(ex))
            {
                // Existing DB was created by EnsureCreated (no migrations history) or has
                // an incompatible schema — safe to rebuild; the file was backed up above.
                AppLog.Warn("App", $"检测到旧版/不兼容数据库（备份: {backupPath ?? "无"}），删除重建: {ex.Message}");
                await db.Database.EnsureDeletedAsync();
                await db.Database.MigrateAsync();
            }
            catch (Exception ex)
            {
                AppLog.Error("App", "数据库迁移失败，数据可能受损", ex);
                MessageBox.Show(
                    LocalizationManager.Format("AppDbMigrationFailedBody", ex.Message,
                        backupPath ?? LocalizationManager.Get("AppDbBackupUnavailable")),
                    LocalizationManager.Get("AppDbErrorTitle"), MessageBoxButton.OK, MessageBoxImage.Error);
                throw;
            }

            // Enable WAL mode so concurrent reads (HistoryWindow) don't block
            // the main app's writes (transcript inserts) and vice versa.
            await db.Database.ExecuteSqlRawAsync("PRAGMA journal_mode=WAL;");
            await db.Database.ExecuteSqlRawAsync("PRAGMA synchronous=NORMAL;");
        }

        // ── 3a. First-run privacy notice ──────────────────────────────────
        if (!SecureStorage.Exists(SecureStorageKeys.PrivacyAccepted))  // first-run
        {
            var privacy = new PrivacyNoticeWindow();
            var accepted = privacy.ShowDialog();
            if (accepted != true)
            {
                Shutdown(0);
                return;
            }
        }

        // ── 4. Show main floating window ──────────────────────────────────
        var floatingWindow = _host.Services.GetRequiredService<FloatingWindow>();
        floatingWindow.Show();
        MainWindow = floatingWindow;

        // ── 4a. Start single-instance activation listener ─────────────────
        _singleInstanceGuard.StartActivationListener(() =>
        {
            Application.Current.Dispatcher.Invoke(() => ShowMainWindow(floatingWindow));
        });

        // ── 5. System tray icon ───────────────────────────────────────────
        _trayIcon = new NativeTrayIcon(LocalizationManager.Get("TrayTooltip"));
        ConfigureTrayIcon(_trayIcon, floatingWindow);
        LocalizationManager.Instance.LanguageChanged += (_, _) =>
            Application.Current.Dispatcher.Invoke(() =>
            {
                _trayIcon.SetTooltip(LocalizationManager.Get("TrayTooltip"));
                _trayIcon.ContextMenu = BuildTrayMenu(floatingWindow);
            });

        // ── 6. First-run: open Settings if no LLM profile configured ──
        if (!SecureStorage.Exists(SecureStorageKeys.LlmProfiles))
        {
            var settings = _host.Services.GetRequiredService<SettingsWindow>();
            settings.Owner = floatingWindow;
            settings.Show();
        }

        } // end try
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), LocalizationManager.Get("AppLaunchFailedTitle"),
                MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    // ── System tray ───────────────────────────────────────────────────────

    private static bool IsLegacySchemaError(Exception ex)
    {
        for (var e = ex; e is not null; e = e.InnerException)
        {
            if (e is Microsoft.Data.Sqlite.SqliteException sqlite &&
                (sqlite.Message.Contains("no such table", StringComparison.OrdinalIgnoreCase) ||
                 sqlite.Message.Contains("no such column", StringComparison.OrdinalIgnoreCase)))
                return true;
        }
        return false;
    }

    private SettingsWindow? _settingsWindow;
    private HistoryWindow?  _historyWindow;

    private static System.Drawing.Icon CreateAppIcon()
    {
        // Load icon.png from embedded resources, scale to 32×32, convert to HICON.
        var asm        = System.Reflection.Assembly.GetExecutingAssembly();
        var streamName = $"{asm.GetName().Name}.icon.png";
        using var stream = asm.GetManifestResourceStream(streamName)
            ?? throw new InvalidOperationException($"Embedded resource '{streamName}' not found.");

        using var src = new System.Drawing.Bitmap(stream);
        using var bmp = new System.Drawing.Bitmap(src, 32, 32);
        var hIcon = bmp.GetHicon();
        return System.Drawing.Icon.FromHandle(hIcon);
    }

    private void ConfigureTrayIcon(NativeTrayIcon tray, FloatingWindow floatingWindow)
    {
        using var icon = CreateAppIcon();
        tray.SetIcon(icon);

        tray.DoubleClick += () => Application.Current.Dispatcher.Invoke(
            () => ShowMainWindow(floatingWindow));

        tray.ContextMenu = BuildTrayMenu(floatingWindow);
    }

    // Built via a method (not inline) so the menu can be rebuilt when the UI language changes.
    private ContextMenu BuildTrayMenu(FloatingWindow floatingWindow)
    {
        var menu = new ContextMenu();

        var showItem = new MenuItem { Header = LocalizationManager.Get("TrayShowMain") };
        showItem.Click += (_, _) => ShowMainWindow(floatingWindow);
        menu.Items.Add(showItem);

        var historyItem = new MenuItem { Header = LocalizationManager.Get("TrayHistory") };
        historyItem.Click += (_, _) =>
        {
            if (_historyWindow is null)
            {
                _historyWindow = _host!.Services.GetRequiredService<HistoryWindow>();
                _historyWindow.Closed += (_, _) => _historyWindow = null;
                _historyWindow.Show();
            }
            if (_historyWindow.WindowState == WindowState.Minimized)
                _historyWindow.WindowState = WindowState.Normal;
            _historyWindow.Activate();
        };
        menu.Items.Add(historyItem);

        var settingsItem = new MenuItem { Header = LocalizationManager.Get("TraySettings") };
        settingsItem.Click += (_, _) =>
        {
            ShowMainWindow(floatingWindow);
            if (_settingsWindow is null)
            {
                _settingsWindow = _host!.Services.GetRequiredService<SettingsWindow>();
                _settingsWindow.Owner = floatingWindow;
                _settingsWindow.Closed += (_, _) => _settingsWindow = null;
                _settingsWindow.Show();
            }
            if (_settingsWindow.WindowState == WindowState.Minimized)
                _settingsWindow.WindowState = WindowState.Normal;
            _settingsWindow.Activate();
        };
        menu.Items.Add(settingsItem);

        var logItem = new MenuItem { Header = LocalizationManager.Get("TrayOpenLogs") };
        logItem.Click += (_, _) =>
        {
            try { System.Diagnostics.Process.Start("explorer.exe", AppLog.LogDirectory); }
            catch { }
        };
        menu.Items.Add(logItem);

        menu.Items.Add(new Separator());

        var exitItem = new MenuItem { Header = LocalizationManager.Get("TrayExit") };
        exitItem.Click += (_, _) =>
        {
            (_host?.Services.GetService<FloatingWindow>())?.MarkExiting();
            Shutdown();
        };
        menu.Items.Add(exitItem);

        return menu;
    }

    private static void ShowMainWindow(FloatingWindow window) => window.RestoreFromTray();

    // ── Cleanup ───────────────────────────────────────────────────────────

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        AppLog.Info("App", "=== MeetingQ exiting ===");

        if (_host is not null)
        {
            // Wait (bounded) for an in-progress session finalization so the last
            // transcripts/summary aren't lost when the user quits mid-session.
            try
            {
                var pending = _host.Services.GetService<FloatingWindowViewModel>()?.PendingEndSessionTask;
                if (pending is not null && !pending.Wait(TimeSpan.FromSeconds(15)))
                    AppLog.Warn("App", "会话收尾任务 15 秒内未完成，强制退出");
            }
            catch { }

            // Synchronous shutdown — async void OnExit yields control before awaits complete,
            // so we block here to guarantee all services are cleaned up before the process exits.
            try { _host.StopAsync(TimeSpan.FromSeconds(3)).GetAwaiter().GetResult(); }
            catch { }
            _host.Dispose();
        }
        _singleInstanceGuard?.Dispose();
        AppLog.Close();
        base.OnExit(e);

        // Some background threads (WASAPI, WebSocket, timers) are not IHostedService and
        // won't stop automatically. Force-terminate the process so nothing lingers in tray.
        Environment.Exit(e.ApplicationExitCode);
    }
}
