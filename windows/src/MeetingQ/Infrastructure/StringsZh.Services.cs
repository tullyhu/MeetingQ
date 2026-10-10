namespace MeetingQ.Infrastructure;

/// <summary>
/// Chinese strings for Services/*, App.xaml.cs (MessageBoxes + tray menu).
/// Prompt-level LLM strings branch inline on LocalizationManager.IsEnglish
/// and do NOT live here. StringsEn mirrors every key.
/// </summary>
internal static partial class StringsZh
{
    private static IEnumerable<KeyValuePair<string, string>> ServiceEntries => new Dictionary<string, string>
    {
        // ── System tray ─────────────────────────────────────────────────
        ["TrayTooltip"]  = "MeetingQ — 双击显示主窗口",
        ["TrayShowMain"] = "显示主窗口",
        ["TrayHistory"]  = "历史会议…",
        ["TraySettings"] = "设置…",
        ["TrayOpenLogs"] = "打开日志目录",
        ["TrayExit"]     = "退出 MeetingQ",

        // ── App startup / crash dialogs ─────────────────────────────────
        ["AppStartupErrorTitle"]   = "MeetingQ 启动错误",
        ["AppRuntimeErrorTitle"]   = "MeetingQ 运行错误",
        ["AppDbErrorTitle"]        = "MeetingQ 数据库错误",
        ["AppDbMigrationFailedBody"] = "数据库迁移失败：{0}\n\n你的会议数据可能受损。数据库备份文件：\n{1}",
        ["AppDbBackupUnavailable"] = "（备份失败，无可用备份）",
        ["AppLaunchFailedTitle"]   = "MeetingQ 启动失败",

        // ── Vision screenshot analysis (tooltips / exports) ─────────────
        ["LlmNotConfigured"] = "未配置 LLM 接口，请在设置 → 大模型 中添加并激活一个配置",
        ["LlmVisionNoBaseUrl"] = "Vision 接口地址未配置",
        ["LlmVisionNoApiKey"] = "Vision API Key 未配置",
        ["LlmVisionNoModelId"] = "Vision 模型 ID 未配置",
        ["LlmProfileNoApiKey"] = "LLM 配置「{0}」的 API Key 为空",
        ["LlmProfileNoBaseUrl"] = "LLM 配置「{0}」的接口地址为空",
        ["LlmHttpError"] = "LLM 返回错误 (HTTP {0})，请检查 API Key 和接口配置",
        ["VisionUnavailableCircuit"] = "分析暂不可用（连续失败）",
        ["VisionImageReadFailed"]    = "图片读取失败",
        ["VisionNoTranscript"]       = "（无）",
        ["VisionTopicNotDetected"]   = "（未检测）",
        ["VisionTimeout"]            = "分析超时",
        ["VisionFailed"]             = "分析失败: {0}",
        ["VisionEmptyAnalysis"]      = "模型未返回有效分析内容",
        ["VisionParseFailed"]        = "响应解析失败",

        // ── ASR ─────────────────────────────────────────────────────────
        ["AsrLocalError"]           = "本地语音识别出错：{0}",
        ["AsrModelDownloading"]     = "正在下载模型 {0} ...",
        ["AsrModelFileTooSmall"]    = "文件过小（{0} bytes），可能已损坏",
        ["AsrModelDownloadFailed"]  = "模型 {0} 下载失败，请检查网络后重试。",

        // ── Audio capture ───────────────────────────────────────────────
        ["AudioDefaultPlaybackDevice"] = "默认播放设备",
    };
}
