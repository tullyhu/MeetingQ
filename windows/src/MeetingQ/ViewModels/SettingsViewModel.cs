using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MeetingQ.Data;
using MeetingQ.Infrastructure;
using MeetingQ.Models;
using MeetingQ.Services;
using MeetingQ.Services.Interfaces;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using NAudio.CoreAudioApi;
using System.Collections.ObjectModel;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
namespace MeetingQ.ViewModels;

// ── Editable wrapper for a single LlmProfile ──────────────────────────────────

public partial class LlmProfileItem : ObservableObject
{
    public Guid Id { get; init; } = Guid.NewGuid();

    [ObservableProperty] private string _name    = string.Empty;
    [ObservableProperty] private string _baseUrl = string.Empty;
    [ObservableProperty] private string _apiKey  = string.Empty;
    [ObservableProperty] private string _modelId = string.Empty;
    [ObservableProperty] private bool   _isActive;
    [ObservableProperty] private string _visionModelId = string.Empty;
    [ObservableProperty] private string _compressionModelId = string.Empty;

    public LlmProfile ToModel() => new()
    {
        Id       = Id,
        Name     = Name,
        BaseUrl  = BaseUrl,
        ApiKey   = ApiKey,
        ModelId  = ModelId,
        IsActive = IsActive,
        VisionModelId = string.IsNullOrWhiteSpace(VisionModelId) ? null : VisionModelId,
        CompressionModelId = string.IsNullOrWhiteSpace(CompressionModelId) ? null : CompressionModelId
    };

    public static LlmProfileItem FromModel(LlmProfile p) => new()
    {
        Id       = p.Id,
        Name     = p.Name,
        BaseUrl  = p.BaseUrl,
        ApiKey   = p.ApiKey,
        ModelId  = p.ModelId,
        IsActive = p.IsActive,
        VisionModelId = p.VisionModelId ?? string.Empty,
        CompressionModelId = p.CompressionModelId ?? string.Empty
    };
}

// ── Main SettingsViewModel ─────────────────────────────────────────────────────

public partial class SettingsViewModel : ObservableObject
{
    private readonly ILlmService            _llmService;
    private readonly IAsrService            _asrService;
    private readonly INameDetectionService  _nameDetection;
    private readonly IDbContextFactory<AppDbContext> _dbFactory;
    private readonly ILogger<SettingsViewModel> _logger;

    // --- 个人身份 ---
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(GenerateAsrVariantsCommand))]
    private string _userName = string.Empty;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(GenerateAsrVariantsCommand))]
    private string _userNicknames = string.Empty;
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(GenerateAsrVariantsCommand))]
    private string _userAsrVariants = string.Empty;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(GenerateAsrVariantsCommand))]
    private bool   _isGeneratingAsrVariants;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasAsrVariantsError))]
    private string _asrVariantsError = string.Empty;
    public bool HasAsrVariantsError => !string.IsNullOrEmpty(AsrVariantsError);

    [ObservableProperty] private string _userRole = string.Empty;

    // --- 界面语言 / UI language ---
    // 0 = follow system, 1 = 中文, 2 = English. Applied & persisted immediately on change.
    [ObservableProperty] private int _languageIndex;

    partial void OnLanguageIndexChanged(int value)
    {
        if (_loadingSettings) return; // initial load — don't re-apply/re-persist
        var pref = value switch
        {
            1 => AppLanguage.Chinese,
            2 => AppLanguage.English,
            _ => AppLanguage.System,
        };
        LocalizationManager.Instance.Preference = pref;
        var stored = pref switch
        {
            AppLanguage.Chinese => "zh-CN",
            AppLanguage.English => "en",
            _ => "system",
        };
        try { SecureStorage.Save(SecureStorageKeys.Language, stored); }
        catch (Exception ex) { _logger.LogWarning(ex, "[Settings] Failed to persist language"); }
    }

    // --- 麦克风采集 ---
    [ObservableProperty] private bool   _micEnabled    = false;
    [ObservableProperty] private string _micDeviceName = string.Empty;
    public ObservableCollection<string> MicDeviceNames { get; } = new();

    [RelayCommand]
    private void RefreshMicDevices()
    {
        MicDeviceNames.Clear();
        MicDeviceNames.Add(LocalizationManager.Get("SetDefaultMic"));
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var dev in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                using (dev)
                    MicDeviceNames.Add(dev.FriendlyName);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Settings] Failed to enumerate mic devices");
        }
    }


    // --- 大模型列表 ---
    public ObservableCollection<LlmProfileItem> LlmProfiles  { get; } = new();
    public ObservableCollection<string>         AvailableModels { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelectedProfile))]
    [NotifyCanExecuteChangedFor(nameof(FetchModelsCommand))]
    private LlmProfileItem? _selectedProfile;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(FetchModelsCommand))]
    private bool _isFetchingModels;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasModelsFetchError))]
    private string _modelsFetchError = string.Empty;
    public bool HasModelsFetchError => !string.IsNullOrEmpty(ModelsFetchError);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSaveStatus))]
    [NotifyPropertyChangedFor(nameof(SaveStatusIsError))]
    private string _saveStatus = string.Empty;
    public bool HasSaveStatus => !string.IsNullOrEmpty(SaveStatus);

    private bool _saveFailed;
    public bool SaveStatusIsError => _saveFailed;

    /// <summary>Sets <see cref="SaveStatus"/> and tracks whether it represents an error.</summary>
    private void SetSaveStatus(string status, bool isError)
    {
        _saveFailed = isError;
        SaveStatus  = status;
        OnPropertyChanged(nameof(SaveStatusIsError));
    }

    public bool HasSelectedProfile => SelectedProfile is not null;

    private static readonly HttpClient _httpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(10)
    };

    // --- 数据目录 ---
    [ObservableProperty] private string _dataDirectory = string.Empty;
    [ObservableProperty] private string _dataDirStatus  = string.Empty;
    public bool IsDataDirDefault => DataDirectory == StorageConfig.DefaultDir;

    // --- 截图配置 ---
    [ObservableProperty] private string _captureWindowTitle = string.Empty;

    // --- Vision 独立提供商（跨供应商分流） ---
    [ObservableProperty] private string _visionProviderBaseUrl = string.Empty;
    [ObservableProperty] private string _visionProviderApiKey  = string.Empty;
    [ObservableProperty] private string _visionProviderModelId = string.Empty;

    public ObservableCollection<string> AvailableWindows { get; } = new();

    [RelayCommand]
    private void RefreshWindows()
    {
        AvailableWindows.Clear();
        var titles = new List<string>();
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hwnd, sb, 256);
            var title = sb.ToString().Trim();
            if (title.Length > 1 && !title.Equals("MeetingQ", StringComparison.Ordinal))
                titles.Add(title);
            return true;
        }, IntPtr.Zero);
        foreach (var t in titles.Distinct().OrderBy(t => t))
            AvailableWindows.Add(t);
    }

    /// <summary>Raised when the view should open a FolderBrowserDialog for data dir.</summary>
    public event Func<string, string?>? BrowseDataDirRequested;

    [RelayCommand]
    private void BrowseDataDirectory()
    {
        var chosen = BrowseDataDirRequested?.Invoke(DataDirectory);
        if (chosen is not null)
            DataDirectory = chosen;
    }

    [RelayCommand]
    private void MigrateDataDirectory()
    {
        var current = StorageConfig.GetStorageDir();
        if (string.IsNullOrWhiteSpace(DataDirectory) || DataDirectory == current)
        {
            DataDirStatus = LocalizationManager.Get("SetDirUnchanged");
            return;
        }
        try
        {
            var count = StorageConfig.MigrateData(current, DataDirectory);
            DataDirStatus = count > 0
                ? LocalizationManager.Format("SetDirMigratedFmt", count)
                : LocalizationManager.Get("SetDirReady");
        }
        catch (Exception ex)
        {
            DataDirStatus = LocalizationManager.Format("SetDirMigrateFailFmt", ex.Message);
        }
    }

    [RelayCommand]
    private void OpenDataDirectory()
    {
        var dir = Directory.Exists(DataDirectory) ? DataDirectory : StorageConfig.GetStorageDir();
        try { System.Diagnostics.Process.Start("explorer.exe", dir); }
        catch { }
    }

    partial void OnDataDirectoryChanged(string value)
    {
        OnPropertyChanged(nameof(IsDataDirDefault));
        DataDirStatus = string.Empty;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMax);

    // --- 测试 / 状态 ---
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasConnectionTestResult))]
    private string _connectionTestResult = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasAsrTestResult))]
    private string _asrTestResult = string.Empty;

    /// <summary>True after the LLM connection test succeeds; drives the XAML result styling.</summary>
    [ObservableProperty] private bool _llmTestSucceeded;

    /// <summary>True after the local ASR test succeeds; drives the XAML result styling.</summary>
    [ObservableProperty] private bool _asrTestSucceeded;

    public bool HasConnectionTestResult => !string.IsNullOrEmpty(ConnectionTestResult);
    public bool HasAsrTestResult        => !string.IsNullOrEmpty(AsrTestResult);

    // --- 统计 ---
    [ObservableProperty] private string _statsSessions    = "—";
    [ObservableProperty] private string _statsTotalTime   = "—";
    [ObservableProperty] private string _statsTranscripts = "—";
    [ObservableProperty] private string _statsScreenshots = "—";
    [ObservableProperty] private bool   _statsLoading     = false;

    /// <summary>Fired when saved settings require an app restart to take effect.</summary>
    public event Action? RestartRequired;

    // Snapshot of restart-sensitive values at load time
    private string _savedDataDirectory = string.Empty;

    public SettingsViewModel(
        ILlmService llmService,
        IAsrService asrService,
        INameDetectionService nameDetection,
        IDbContextFactory<AppDbContext> dbFactory,
        VoiceprintLibraryService voiceprints,
        ILogger<SettingsViewModel> logger)
    {
        _llmService    = llmService;
        _asrService    = asrService;
        _nameDetection = nameDetection;
        _dbFactory     = dbFactory;
        _voiceprints   = voiceprints;
        _logger        = logger;
        LoadFromSecureStorage();
        _ = LoadVoiceprintsAsync();
    }

    // ── 声纹库 (W2) ──────────────────────────────────────────────────────

    private readonly VoiceprintLibraryService _voiceprints;

    public partial class VoiceprintItem : ObservableObject
    {
        public long Id { get; init; }
        [ObservableProperty] private string _name = string.Empty;
        [ObservableProperty] private bool _isSelected;
        public string Meta { get; init; } = string.Empty;
        public DateTime LastHeardAt { get; init; }
        public string DisplayName => string.IsNullOrWhiteSpace(Name)
            ? LocalizationManager.Get("VoiceprintUnnamed") : Name;
    }

    public ObservableCollection<VoiceprintItem> Voiceprints { get; } = new();

    [RelayCommand]
    private async Task LoadVoiceprintsAsync()
    {
        var all = await _voiceprints.FetchAllAsync();
        Voiceprints.Clear();
        var unnamed = 0;
        foreach (var s in all)
        {
            var name = s.Name;
            if (string.IsNullOrWhiteSpace(name)) name = $"{LocalizationManager.Get("VoiceprintUnnamed")} {++unnamed}";
            Voiceprints.Add(new VoiceprintItem
            {
                Id = s.Id,
                Name = name,
                Meta = string.Format(LocalizationManager.Get("VoiceprintMeta"),
                    s.SampleCount, s.LastHeardAt.ToString("MM-dd HH:mm")),
                LastHeardAt = s.LastHeardAt,
            });
        }
    }

    [RelayCommand]
    private async Task RenameVoiceprintAsync(VoiceprintItem? item)
    {
        if (item is null) return;
        var dlg = new MeetingQ.Views.SpeakerRenameDialog(new[] { item.Name }, async (_, newName) =>
        {
            await _voiceprints.RenameAsync(item.Id, newName);
            return true;
        });
        dlg.ShowDialog();
        await LoadVoiceprintsAsync();
    }

    [RelayCommand]
    private async Task DeleteVoiceprintAsync(VoiceprintItem? item)
    {
        if (item is null) return;
        await _voiceprints.DeleteAsync(item.Id);
        await LoadVoiceprintsAsync();
    }

    [RelayCommand]
    private async Task MergeSelectedVoiceprintsAsync()
    {
        var selected = Voiceprints.Where(v => v.IsSelected).ToList();
        if (selected.Count < 2) return;
        // Merge everything into the most-recently-heard entry.
        var winner = selected.OrderByDescending(v => v.LastHeardAt).First();
        foreach (var loser in selected.Where(v => v.Id != winner.Id))
            await _voiceprints.MergeAsync(winner.Id, loser.Id);
        await LoadVoiceprintsAsync();
    }

    [RelayCommand]
    private async Task ClearAllVoiceprintsAsync()
    {
        var confirm = System.Windows.MessageBox.Show(
            LocalizationManager.Get("VoiceprintClearConfirm"),
            LocalizationManager.Get("VoiceprintClearAll"),
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);
        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await _voiceprints.ClearAllAsync();
        await LoadVoiceprintsAsync();
    }

    // ── 会议自动检测 (W5) ────────────────────────────────────────────────

    public string MeetingAutoDetectMode
    {
        get => SecureStorage.Load(SecureStorageKeys.MeetingAutoDetectMode) ?? "prompt";
        set
        {
            SecureStorage.Save(SecureStorageKeys.MeetingAutoDetectMode, value);
            OnPropertyChanged();
        }
    }

    private bool _loadingSettings;

    private void LoadFromSecureStorage()
    {
        _loadingSettings = true;
        try
        {
        UserName        = SecureStorage.Load(SecureStorageKeys.UserName)        ?? string.Empty;
        UserNicknames   = SecureStorage.Load(SecureStorageKeys.UserNicknames)   ?? string.Empty;
        UserAsrVariants = SecureStorage.Load(SecureStorageKeys.UserAsrVariants) ?? string.Empty;
        UserRole        = SecureStorage.Load(SecureStorageKeys.UserRole)        ?? string.Empty;

        CaptureWindowTitle = SecureStorage.Load(SecureStorageKeys.CaptureWindowTitle) ?? string.Empty;

        VisionProviderBaseUrl = SecureStorage.Load(SecureStorageKeys.VisionProviderBaseUrl) ?? string.Empty;
        VisionProviderApiKey  = SecureStorage.Load(SecureStorageKeys.VisionProviderApiKey)  ?? string.Empty;
        VisionProviderModelId = SecureStorage.Load(SecureStorageKeys.VisionProviderModelId) ?? string.Empty;

        MicEnabled    = SecureStorage.Load(SecureStorageKeys.MicEnabled) == "true";
        MicDeviceName = SecureStorage.Load(SecureStorageKeys.MicDeviceName) ?? string.Empty;

        // UI language — reflects what App.xaml.cs already applied at startup.
        LanguageIndex = SecureStorage.Load(SecureStorageKeys.Language) switch
        {
            "zh-CN" => 1,
            "en"    => 2,
            _       => 0,
        };

        DataDirectory         = StorageConfig.GetStorageDir();
        _savedDataDirectory   = DataDirectory;
        DataDirStatus = string.Empty;

        // Load LLM profiles
        LlmProfiles.Clear();
        foreach (var p in LlmProfileStore.Load())
            LlmProfiles.Add(LlmProfileItem.FromModel(p));

        SelectedProfile = LlmProfiles.FirstOrDefault(p => p.IsActive) ?? LlmProfiles.FirstOrDefault();

        RefreshMicDevices();
        }
        finally { _loadingSettings = false; }
    }

    // ── LLM profile management ────────────────────────────────────────────────

    [RelayCommand]
    private void AddProfile()
    {
        var item = new LlmProfileItem
        {
            Name    = LocalizationManager.Get("SetNewProfile"),
            BaseUrl = "https://api.openai.com/v1",
            ModelId = "gpt-4o-mini"
        };
        LlmProfiles.Add(item);
        SelectedProfile = item;
    }

    [RelayCommand(CanExecute = nameof(HasSelectedProfile))]
    private void DeleteProfile()
    {
        if (SelectedProfile is null) return;
        var idx = LlmProfiles.IndexOf(SelectedProfile);
        LlmProfiles.Remove(SelectedProfile);
        // re-select nearest
        SelectedProfile = LlmProfiles.Count > 0
            ? LlmProfiles[Math.Min(idx, LlmProfiles.Count - 1)]
            : null;
        // ensure exactly one active
        EnsureOneActive();
    }

    [RelayCommand(CanExecute = nameof(HasSelectedProfile))]
    private void SetActiveProfile()
    {
        if (SelectedProfile is null) return;
        foreach (var p in LlmProfiles) p.IsActive = false;
        SelectedProfile.IsActive = true;
    }

    partial void OnSelectedProfileChanged(LlmProfileItem? value)
    {
        DeleteProfileCommand.NotifyCanExecuteChanged();
        SetActiveProfileCommand.NotifyCanExecuteChanged();
        AvailableModels.Clear();
        ModelsFetchError = string.Empty;
    }

    private void EnsureOneActive()
    {
        if (LlmProfiles.Count == 0) return;
        if (!LlmProfiles.Any(p => p.IsActive))
            LlmProfiles[0].IsActive = true;
    }

    private bool CanFetchModels() => !IsFetchingModels
        && SelectedProfile is not null
        && !string.IsNullOrWhiteSpace(SelectedProfile.BaseUrl);

    [RelayCommand(CanExecute = nameof(CanFetchModels))]
    private async Task FetchModelsAsync()
    {
        if (SelectedProfile is null) return;
        IsFetchingModels = true;
        AvailableModels.Clear();
        ModelsFetchError = string.Empty;
        try
        {
            var baseUrl = SelectedProfile.BaseUrl.TrimEnd('/');
            var url     = $"{baseUrl}/models";

            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            if (!string.IsNullOrWhiteSpace(SelectedProfile.ApiKey))
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", SelectedProfile.ApiKey);

            using var resp = await _httpClient.SendAsync(req);
            resp.EnsureSuccessStatusCode();

            using var doc  = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            var models = doc.RootElement
                .GetProperty("data")
                .EnumerateArray()
                .Select(m => m.GetProperty("id").GetString() ?? string.Empty)
                .Where(id => id.Length > 0)
                .OrderBy(id => id)
                .ToList();

            foreach (var m in models)
                AvailableModels.Add(m);

            _logger.LogInformation("[Settings] Fetched {Count} models from {Url}", models.Count, url);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[Settings] Failed to fetch models");
            ModelsFetchError = LocalizationManager.Format("SetModelsFetchFailFmt", ex.Message);
        }
        finally
        {
            IsFetchingModels = false;
        }
    }

    // ── Config clear ─────────────────────────────────────────────────────────

    /// <summary>View raises this to confirm before clearing. Returns true to proceed.</summary>
    public event Func<bool>? ConfirmClearRequested;

    [RelayCommand]
    private void ClearAllConfig()
    {
        if (ConfirmClearRequested?.Invoke() != true) return;

        try
        {
            var dir = StorageConfig.GetStorageDir();
            foreach (var f in Directory.GetFiles(dir, "*.dat"))
                File.Delete(f);

            StorageConfig.ResetCache();
            LoadFromSecureStorage();
            _nameDetection.ReloadNames();

            _logger.LogInformation("All config cleared");
            DataDirStatus = LocalizationManager.Get("SetConfigCleared");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Clear config failed");
            DataDirStatus = LocalizationManager.Format("SetClearFailFmt", ex.Message);
        }
    }

    // ── Config import / export ──────────────────────────────────────────────

    public event Func<string, string?>? ExportConfigPathRequested;
    public event Func<string, string?>? ImportConfigPathRequested;
    public event Func<string, bool>? ConfirmConfigOverwriteRequested;

    private sealed record ConfigExport(
        int Version,
        string ExportedAt,
        string UserName,
        string UserNicknames,
        string UserAsrVariants,
        string UserRole,
        string CaptureWindowTitle,
        string? VisionProviderBaseUrl,
        string? VisionProviderApiKey,
        string? VisionProviderModelId,
        bool MicEnabled,
        string MicDeviceName,
        List<ConfigExportProfile> LlmProfiles
    );

    private sealed record ConfigExportProfile(
        string Name,
        string BaseUrl,
        string ApiKey,
        string ModelId,
        bool IsActive,
        string? VisionModelId,
        string? CompressionModelId
    );

    [RelayCommand]
    private void ExportConfig()
    {
        try
        {
            // Export the current form contents only — never persist as a side effect
            EnsureOneActive();

            var export = new ConfigExport(
                Version: 1,
                ExportedAt: DateTime.Now.ToString("O"),
                UserName: UserName,
                UserNicknames: UserNicknames,
                UserAsrVariants: UserAsrVariants,
                UserRole: UserRole,
                CaptureWindowTitle: CaptureWindowTitle,
                VisionProviderBaseUrl: string.IsNullOrWhiteSpace(VisionProviderBaseUrl) ? null : VisionProviderBaseUrl,
                VisionProviderApiKey: string.IsNullOrWhiteSpace(VisionProviderApiKey) ? null : VisionProviderApiKey,
                VisionProviderModelId: string.IsNullOrWhiteSpace(VisionProviderModelId) ? null : VisionProviderModelId,
                MicEnabled: MicEnabled,
                MicDeviceName: MicDeviceName,
                LlmProfiles: LlmProfiles.Select(p => new ConfigExportProfile(
                    p.Name,
                    p.BaseUrl,
                    p.ApiKey,
                    p.ModelId,
                    p.IsActive,
                    string.IsNullOrWhiteSpace(p.VisionModelId) ? null : p.VisionModelId,
                    string.IsNullOrWhiteSpace(p.CompressionModelId) ? null : p.CompressionModelId
                )).ToList()
            );

            var defaultName = $"MeetingQ_Config_{DateTime.Now:yyyyMMdd_HHmm}.json";
            var path = ExportConfigPathRequested?.Invoke(defaultName);
            if (path is null) return;

            var json = JsonSerializer.Serialize(export, new JsonSerializerOptions
            {
                WriteIndented = true,
                Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
            });
            File.WriteAllText(path, json, Encoding.UTF8);

            DataDirStatus = LocalizationManager.Format("SetConfigExportedFmt", Path.GetFileName(path));
            _logger.LogInformation("[Settings] Config exported to {Path}", path);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Settings] Config export failed");
            DataDirStatus = LocalizationManager.Format("SetExportFailFmt", ex.Message);
        }
    }

    [RelayCommand]
    private void ImportConfig()
    {
        try
        {
            var defaultName = "MeetingQ_Config_*.json";
            var path = ImportConfigPathRequested?.Invoke(defaultName);
            if (path is null || !File.Exists(path)) return;

            if (ConfirmConfigOverwriteRequested?.Invoke(
                LocalizationManager.Get("SetImportConfirm")) != true)
                return;

            var json = File.ReadAllText(path, Encoding.UTF8);
            var import = JsonSerializer.Deserialize<ConfigExport>(json);
            if (import is null || import.Version != 1 || import.LlmProfiles is null)
            {
                DataDirStatus = LocalizationManager.Get("SetImportInvalidFormat");
                return;
            }
            if (import.LlmProfiles.Any(p =>
                    p is null || string.IsNullOrWhiteSpace(p.BaseUrl) || string.IsNullOrWhiteSpace(p.ModelId)))
            {
                DataDirStatus = LocalizationManager.Get("SetImportInvalidProfile");
                return;
            }

            UserName        = import.UserName        ?? string.Empty;
            UserNicknames   = import.UserNicknames   ?? string.Empty;
            UserAsrVariants = import.UserAsrVariants ?? string.Empty;
            UserRole        = import.UserRole        ?? string.Empty;
            CaptureWindowTitle    = import.CaptureWindowTitle ?? string.Empty;
            VisionProviderBaseUrl = import.VisionProviderBaseUrl ?? string.Empty;
            VisionProviderApiKey  = import.VisionProviderApiKey  ?? string.Empty;
            VisionProviderModelId = import.VisionProviderModelId ?? string.Empty;
            MicEnabled    = import.MicEnabled;
            MicDeviceName = import.MicDeviceName ?? string.Empty;

            LlmProfiles.Clear();
            foreach (var p in import.LlmProfiles)
            {
                LlmProfiles.Add(new LlmProfileItem
                {
                    Name              = string.IsNullOrWhiteSpace(p.Name) ? LocalizationManager.Get("SetUnnamedProfile") : p.Name,
                    BaseUrl           = p.BaseUrl ?? string.Empty,
                    ApiKey            = p.ApiKey ?? string.Empty,
                    ModelId           = p.ModelId ?? string.Empty,
                    IsActive          = p.IsActive,
                    VisionModelId     = p.VisionModelId ?? string.Empty,
                    CompressionModelId = p.CompressionModelId ?? string.Empty
                });
            }
            EnsureOneActive();
            SelectedProfile = LlmProfiles.FirstOrDefault(p => p.IsActive) ?? LlmProfiles.FirstOrDefault();

            // Persist immediately
            SaveSettingsCommand.Execute(null);

            DataDirStatus = LocalizationManager.Format("SetConfigImportedFmt", Path.GetFileName(path));
            _logger.LogInformation("[Settings] Config imported from {Path}", path);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Settings] Config import failed");
            DataDirStatus = LocalizationManager.Format("SetImportFailFmt", ex.Message);
        }
    }

    // ── Save / Test ───────────────────────────────────────────────────────────

    [RelayCommand]
    private void SaveSettings()
    {
        _logger.LogInformation("Saving settings");

        try
        {
            SecureStorage.Save(SecureStorageKeys.UserName,        UserName);
            SecureStorage.Save(SecureStorageKeys.UserNicknames,   UserNicknames);
            SecureStorage.Save(SecureStorageKeys.UserAsrVariants, UserAsrVariants);
            SecureStorage.Save(SecureStorageKeys.UserRole,        UserRole);

            SecureStorage.Save(SecureStorageKeys.CaptureWindowTitle, CaptureWindowTitle);
            SecureStorage.Save(SecureStorageKeys.VisionProviderBaseUrl, VisionProviderBaseUrl);
            SecureStorage.Save(SecureStorageKeys.VisionProviderApiKey,  VisionProviderApiKey);
            SecureStorage.Save(SecureStorageKeys.VisionProviderModelId, VisionProviderModelId);
            SecureStorage.Save(SecureStorageKeys.MicEnabled,    MicEnabled ? "true" : "false");
            // Persist empty for the localized "(Default microphone)" placeholder
            SecureStorage.Save(SecureStorageKeys.MicDeviceName,
                MicDeviceName == LocalizationManager.Get("SetDefaultMic") ? string.Empty : MicDeviceName);

            // Apply custom data directory if changed
            var currentDir = StorageConfig.GetStorageDir();
            if (!string.IsNullOrWhiteSpace(DataDirectory) && DataDirectory != currentDir)
            {
                StorageConfig.SetStorageDir(DataDirectory);
                _logger.LogInformation("Data directory changed to {Dir}", DataDirectory);
            }

            // Persist LLM profiles (includes API keys, encrypted via DPAPI)
            EnsureOneActive();
            LlmProfileStore.Save(LlmProfiles.Select(p => p.ToModel()));

            _nameDetection.ReloadNames();

            _logger.LogInformation("Settings saved");

            bool needsRestart = DataDirectory != _savedDataDirectory;

            if (needsRestart)
            {
                SetSaveStatus(LocalizationManager.Get("SetSaveOk"), isError: false);
                RestartRequired?.Invoke();
            }
            else
            {
                SetSaveStatus(LocalizationManager.Get("SetSaveOkCheck"), isError: false);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Settings] Failed to save settings");
            SetSaveStatus(LocalizationManager.Format("SetSaveFailFmt", ex.Message), isError: true);
        }
    }

    private bool CanGenerateAsrVariants() => !IsGeneratingAsrVariants
        && (!string.IsNullOrWhiteSpace(UserName) || !string.IsNullOrWhiteSpace(UserNicknames));

    [RelayCommand(CanExecute = nameof(CanGenerateAsrVariants))]
    private async Task GenerateAsrVariantsAsync()
    {
        IsGeneratingAsrVariants = true;
        AsrVariantsError = string.Empty;
        try
        {
            var names = new List<string>();
            if (!string.IsNullOrWhiteSpace(UserName))
                names.AddRange(UserName.Split(',').Select(n => n.Trim()).Where(n => n.Length > 0));
            if (!string.IsNullOrWhiteSpace(UserNicknames))
                names.AddRange(UserNicknames.Split(',').Select(n => n.Trim()).Where(n => n.Length > 0));

            var namesText = string.Join(LocalizationManager.Instance.IsEnglish ? ", " : "、", names);
            var prompt = LocalizationManager.Instance.IsEnglish
                ? $$"""
                    The user's name/nicknames in meetings: {{namesText}}

                    List common words that English speech recognition (ASR) might mishear each name as.
                    Typical causes: similar sounds, common homophones.

                    Requirements:
                    - 2-4 most likely misrecognitions per name
                    - common English words only, no explanations
                    - return only a comma-separated list

                    Return only the word list:
                    """
                : $$"""
                    用户在会议中使用的姓名/昵称为：{{namesText}}

                    请列举中文语音识别（ASR）可能将上述每个名字误识别成的常见词语。
                    误识别原因通常是：声调不同、声母/韵母相近、读音相似的常用词。

                    要求：
                    - 每个名字列举 2～4 个最可能被误识别成的词
                    - 只列举读音相近的常用汉语词汇，不需要解释
                    - 只返回逗号分隔的词列表，不要任何其他内容

                    只返回词列表：
                    """;

            // 60s cap for generation tasks
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            var reply = await _llmService.AnalyzeAsync(prompt, cts.Token);

            // Strip punctuation / explanatory text; keep only short words
            var variants = reply
                .Split(new[] { ',', '，', '\n', '\r', '、', ';', '；', ' ' },
                       StringSplitOptions.RemoveEmptyEntries)
                .Select(w => w.Trim('。', '！', '？', '"', '\u201C', '\u201D', '\'', '\"', ' ', '\t'))
                .Where(w => w.Length is >= 1 and <= 6)
                .Distinct()
                .ToArray();

            if (variants.Length > 0)
            {
                UserAsrVariants = string.Join(",", variants);
                _logger.LogInformation("[Settings] Generated ASR variants for '{Names}': {Variants}",
                    namesText, string.Join(", ", variants));
            }
            else
            {
                AsrVariantsError = LocalizationManager.Get("SetAsrNoResult");
            }
        }
        catch (OperationCanceledException)
        {
            AsrVariantsError = LocalizationManager.Get("SetAsrGenTimeout");
            _logger.LogWarning("[Settings] ASR variant generation timed out");
        }
        catch (Exception ex)
        {
            AsrVariantsError = LocalizationManager.Format("SetAsrGenFailFmt", ex.Message);
            _logger.LogError(ex, "[Settings] ASR variant generation failed");
        }
        finally
        {
            IsGeneratingAsrVariants = false;
        }
    }

    [RelayCommand]
    private async Task TestConnectionAsync()
    {
        ConnectionTestResult = LocalizationManager.Get("SetTesting");
        LlmTestSucceeded = false;
        _logger.LogInformation("Testing LLM connection");
        try
        {
            var profile = SelectedProfile ?? LlmProfiles.FirstOrDefault(p => p.IsActive);
            if (profile is null)
            {
                ConnectionTestResult = LocalizationManager.Get("SetLlmNoProfile");
                return;
            }
            if (string.IsNullOrWhiteSpace(profile.BaseUrl) || string.IsNullOrWhiteSpace(profile.ApiKey)
                || string.IsNullOrWhiteSpace(profile.ModelId))
            {
                ConnectionTestResult = LocalizationManager.Get("SetLlmMissingFields");
                return;
            }

            var body = new
            {
                model    = profile.ModelId,
                messages = new[]
                {
                    new { role = "system", content = "You are a helpful assistant." },
                    new { role = "user",   content = "Reply with exactly: ok" }
                },
                max_tokens = 8
            };

            var url = profile.BaseUrl.TrimEnd('/') + "/chat/completions";
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", profile.ApiKey);
            req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            using var resp = await _httpClient.SendAsync(req, cts.Token);
            var reply = await resp.Content.ReadAsStringAsync(cts.Token);

            LlmTestSucceeded = resp.IsSuccessStatusCode;
            ConnectionTestResult = resp.IsSuccessStatusCode
                ? LocalizationManager.Get("SetLlmOk")
                : LocalizationManager.Format("SetLlmHttpFailFmt", (int)resp.StatusCode);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "LLM connection test failed");
            LlmTestSucceeded = false;
            ConnectionTestResult = LocalizationManager.Format("SetLlmFailFmt", ex.Message);
        }
    }

    [RelayCommand]
    private async Task TestAsrConnectionAsync()
    {
        AsrTestResult = LocalizationManager.Get("SetAsrTesting");
        AsrTestSucceeded = false;
        _logger.LogInformation("Testing local ASR (sherpa-onnx)");

        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
            await _asrService.ConnectAsync(cts.Token);
            await _asrService.DisconnectAsync(cts.Token);
            AsrTestResult = LocalizationManager.Get("SetAsrReady");
            AsrTestSucceeded = true;
            _logger.LogInformation("ASR test passed");
        }
        catch (OperationCanceledException)
        {
            AsrTestResult = LocalizationManager.Get("SetAsrTimeout");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "ASR test failed");
            AsrTestResult = LocalizationManager.Format("SetAsrFailFmt", ex.Message);
        }
    }

    public async Task LoadStatsAsync()
    {
        StatsLoading = true;
        try
        {
            using var db = _dbFactory.CreateDbContext();

            var count       = await db.Sessions.CountAsync();
            var transcripts = await db.Transcripts.CountAsync();
            var screenshots = await db.Screenshots.CountAsync();

            var totalSecs = await db.Database
                .SqlQuery<double>($"SELECT COALESCE(SUM((julianday(EndTime) - julianday(StartTime)) * 86400.0), 0) AS Value FROM Sessions WHERE EndTime IS NOT NULL")
                .FirstAsync();

            var h = (int)(totalSecs / 3600);
            var m = (int)(totalSecs % 3600 / 60);

            StatsLoading    = false;
            StatsSessions    = LocalizationManager.Format("SetStatsCountFmt", count);
            StatsTotalTime   = h > 0 ? $"{h}h {m}m" : $"{m}m";
            StatsTranscripts = LocalizationManager.Format("SetStatsTranscriptsFmt", transcripts);
            StatsScreenshots = LocalizationManager.Format("SetStatsShotsFmt", screenshots);
        }
        catch (Exception ex)
        {
            StatsLoading  = false;
            StatsSessions = LocalizationManager.Format("SetLoadFailFmt", ex.Message);
            _logger.LogWarning(ex, "Failed to load stats");
        }
    }

    // ── Data clearing ──────────────────────────────────────────────────────

    public event Func<string, bool>? ConfirmDataClearRequested;

    [RelayCommand]
    private async Task ClearTranscriptHistoryAsync()
    {
        if (ConfirmDataClearRequested?.Invoke(
            LocalizationManager.Get("SetClearTranscriptsConfirm")) != true)
            return;

        try
        {
            using var db = _dbFactory.CreateDbContext();
            await db.Transcripts.ExecuteDeleteAsync();
            _logger.LogInformation("[Settings] Transcript history cleared");
            DataDirStatus = LocalizationManager.Get("SetTranscriptsCleared");
            await LoadStatsAsync();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Settings] Failed to clear transcript history");
            DataDirStatus = LocalizationManager.Format("SetClearTranscriptsFailFmt", ex.Message);
        }
    }

    [RelayCommand]
    private async Task ClearScreenshotHistoryAsync()
    {
        if (ConfirmDataClearRequested?.Invoke(
            LocalizationManager.Get("SetClearShotsConfirm")) != true)
            return;

        try
        {
            using var db = _dbFactory.CreateDbContext();

            // Collect file paths before deleting records
            var paths = await db.Screenshots
                .Select(s => s.FilePath)
                .ToListAsync();

            await db.Screenshots.ExecuteDeleteAsync();

            // Delete physical files
            var deleted = 0;
            foreach (var path in paths.Where(p => !string.IsNullOrEmpty(p)))
            {
                try { File.Delete(path!); deleted++; }
                catch (Exception ex) { _logger.LogWarning(ex, "Failed to delete screenshot file {Path}", path); }
            }

            _logger.LogInformation("[Settings] Screenshot history cleared: {Db} records, {Files} files deleted",
                paths.Count, deleted);
            DataDirStatus = LocalizationManager.Get("SetShotsCleared");
            await LoadStatsAsync();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[Settings] Failed to clear screenshot history");
            DataDirStatus = LocalizationManager.Format("SetClearShotsFailFmt", ex.Message);
        }
    }
}
