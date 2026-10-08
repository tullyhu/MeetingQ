# MeetingQ — 详细设计文档

## 1. 概述

MeetingQ 是一个 Windows 桌面会议助手应用，基于 WPF (.NET 8)，提供实时语音转写、AI 摘要、被叫姓名提醒、自动截图等功能。应用以系统托盘（System Tray）方式运行，主窗口为浮动小窗。

### 核心技术栈

| 层级 | 技术选型 |
|------|---------|
| 框架 | .NET 8, WPF, x64 |
| MVVM | CommunityToolkit.Mvvm 8.4 |
| ORM | Entity Framework Core 8 + SQLite |
| 音频 | NAudio 2.2 (WASAPI Loopback) |
| ASR | sherpa-onnx 本地推理（流式 Paraformer + 说话人识别，完全离线） |
| LLM | OpenAI 兼容 API（用户可配置任意 endpoint） |
| DI | Microsoft.Extensions.Hosting |
| 加密 | Windows DPAPI (ProtectedData) |
| TTS 自检 | System.Speech |
| 打包 | Inno Setup, single-file publish |
| 截图 | GDI+ / PrintWindow / CopyFromScreen |

---

## 2. 项目结构

```
MeetingQ.sln
installer/
  MeetingQ.iss              # Inno Setup 安装脚本
src/MeetingQ/
  MeetingQ.csproj
  App.xaml / App.xaml.cs       # 应用入口，DI 容器构建
  app.manifest                  # DPI 感知、asInvoker 权限
  icon.png                      # 嵌入资源—托盘图标
  Data/
    AppDbContext.cs             # EF Core DbContext，SQLite
  Models/
    MeetingSession.cs           # 会议会话
    Topic.cs                    # 议题
    Transcript.cs               # 转录条目
    Screenshot.cs               # 截图记录
    Decision.cs                 # 决策
    Question.cs                 # 问题
    ActionItem.cs               # 行动项
    LlmProfile.cs               # LLM 接口配置
  Infrastructure/
    AppLog.cs                   # 独立文件日志
    SecureStorage.cs            # DPAPI 加密 key-value 存储
    SecureStorageKeys           # 存储 key 常量定义
    StorageConfig.cs            # 可迁移的数据目录管理
    LlmProfileStore.cs          # LLM 配置持久化
    SingleInstanceGuard.cs      # 单实例 Mutex + Named Pipe
    NativeTrayIcon.cs           # Win32 Shell_NotifyIcon 托盘
    PinyinHelper.cs             # 拼音模糊匹配（含 ~600 汉字表）
  Services/
    Interfaces/
      IAudioCaptureService.cs   # 音频采集接口
      IAsrService.cs            # ASR 转写接口
      ISpeakerRefinement.cs     # 会后离线说话人重识别接口（可选能力）
      ILlmService.cs            # LLM 接口
      IScreenCaptureService.cs  # 截图接口
      INameDetectionService.cs  # 姓名检测接口
    AudioCaptureService.cs      # WASAPI 环回采集 + VAD
    SherpaOnnxAsrService.cs     # 本地 ASR（sherpa-onnx 流式 Paraformer + 说话人聚类 + 录音）
    AsrModelManager.cs          # ASR/说话人模型解析与兜底下载
    OnlineSpeakerCluster.cs     # 说话人 embedding 在线质心聚类
    ConfigurableLlmService.cs   # OpenAI 兼容 LLM
    ScreenCaptureService.cs     # 周期截图 (8s 轮询) + 去重 + 静音节流
    LocalOcrService.cs          # WinRT 本地 OCR（发言人名/参会人数提取）
    NameDetectionService.cs     # 3 层姓名检测管道
    VadProcessor.cs             # 能量 VAD
    SelfTestAudio.cs            # TTS 自检语音播放
  ViewModels/
    FloatingWindowViewModel.cs  # 主窗口 VM — 核心业务逻辑
    SettingsViewModel.cs        # 设置窗口 VM
    HistoryViewModel.cs         # 历史会议 VM
    ScreenshotAlbumViewModel.cs # 截图时光轴 VM
    DiagnosticItem.cs           # 诊断步骤条目
    ScreenshotItem.cs           # 截图缩略图条目
  Views/
    FloatingWindow.xaml/.cs     # 主浮动窗口
    SettingsWindow.xaml/.cs     # 设置窗口
    HistoryWindow.xaml/.cs      # 历史会议窗口
    NameAlertPopup.xaml/.cs     # 被叫姓名提醒弹窗
    QuickSummaryPopup.xaml/.cs  # 快速摘要弹窗
    ScreenshotAlbumWindow.xaml/.cs # 截图时光轴窗口
    PrivacyNoticeWindow.xaml/.cs  # 首次隐私声明
    FilePathToImageConverter.cs # 文件路径→图片转换器
  Migrations/                   # EF Core 迁移
```

---

## 3. 数据模型

### 3.1 实体关系图

```
MeetingSession (1) ──── (N) Topic (1) ──── (N) Transcript
                   │                     ├─── (N) Decision
                   │                     ├─── (N) Question
                   │                     └─── (N) ActionItem
                   └─── (N) Screenshot
```

### 3.2 MeetingSession

```csharp
public enum SessionStatus { Idle, Monitoring, Ended, Saved }

public class MeetingSession
{
    int       SessionId;     // PK, auto-increment
    DateTime  StartTime;     // 会话开始时间
    DateTime? EndTime;       // 会话结束时间
    SessionStatus Status;    // 状态（字符串存储）
    string?   Title;         // 默认 "会议 MM-dd HH:mm"
    ICollection<Topic>      Topics;
    ICollection<Screenshot> Screenshots;
}
```

### 3.3 Topic

```csharp
public class Topic
{
    int       TopicId;      // PK, auto-increment
    string    Title;        // 议题名称（LLM 自动检测，≤20字）
    DateTime  StartTime;
    DateTime? EndTime;
    int       OrderIndex;   // 排序
    string?   Summary;
    int       SessionId;    // FK → MeetingSession
    MeetingSession Session;
    ICollection<Transcript>  Transcripts;
    ICollection<Decision>    Decisions;
    ICollection<Question>    Questions;
    ICollection<ActionItem>  ActionItems;
}
```

### 3.4 Transcript

```csharp
public class Transcript
{
    int       TranscriptId; // PK, auto-increment
    DateTime  Timestamp;
    string?   Speaker;      // 说话人（可选，姓名检测后可回填）
    string    Text;         // 转录文本
    bool      IsFinal;      // 是否为最终确认的句子
    float     Confidence;
    int       TopicId;      // FK → Topic
    Topic     Topic;
}
```

### 3.5 Screenshot

```csharp
public class Screenshot
{
    int       ScreenshotId; // PK
    DateTime  Timestamp;
    string    FilePath;     // JPEG 文件路径
    string?   ImageHash;    // 64×36 缩略图 MD5（去重用）
    string?   AISummary;    // AI 分析（预留字段）
    int       SessionId;    // FK → MeetingSession
    MeetingSession Session;
}
```

### 3.6 Decision

```csharp
public class Decision
{
    int       DecisionId;   // PK
    DateTime  Timestamp;
    string    DecisionText; // 决策内容
    int       TopicId;      // FK → Topic
    Topic     Topic;
}
```

### 3.7 Question

```csharp
public enum QuestionType { Direct, Indirect, ActionRequired }
public enum QuestionStatus { Pending, Acknowledged, Dismissed }

public class Question
{
    int            QuestionId;          // PK
    DateTime       Timestamp;
    string?        Speaker;
    string         OriginalText;        // 原话
    string?        ExtractedQuestions;  // JSON 数组—提取的子问题
    QuestionType   QuestionType;
    float          Confidence;
    QuestionStatus Status;             // Pending / Acknowledged / Dismissed
    int            TopicId;            // FK → Topic
    Topic          Topic;
}
```

### 3.8 ActionItem

```csharp
public class ActionItem
{
    int       ActionItemId; // PK
    DateTime  Timestamp;
    string    AssignedTo;   // 负责人
    string    Task;         // 任务描述
    string?   Deadline;     // 截止时间（自然语言）
    int       TopicId;      // FK → Topic
    Topic     Topic;
}
```

### 3.9 LlmProfile（仅内存/SecureStorage，不入 SQLite）

```csharp
public class LlmProfile
{
    Guid   Id;       // 配置 ID
    string Name;     // 显示名称
    string BaseUrl;  // OpenAI 兼容端点
    string ApiKey;   // API Key（DPAPI 加密存储）
    string ModelId;  // 模型标识
    bool   IsActive; // 当前激活
}
```

### 3.10 数据库配置

- 数据库文件：`%LOCALAPPDATA%\MeetingQ\meetingq.db`
- 使用 SQLite WAL 模式 + `synchronous=NORMAL`
- EF Core 迁移自动应用（失败时自动删除重建）
- 所有外键使用 Cascade Delete

---

## 4. Infrastructure 层

### 4.1 AppLog — 独立文件日志

```
格式: [HH:mm:ss.fff] [LEVL] [Category] message
路径: %LOCALAPPDATA%\MeetingQ\Logs\meetingq-{timestamp}.log
保留: 最近 10 个日志文件
特点: 不依赖 .NET ILogger，启动最早就绪，AutoFlush
```

提供 4 个级别：`Debug`, `Info`, `Warn`, `Error`；支持泛型类别（`Info<T>()` 自动取 `typeof(T).Name`）和字符串类别两种重载。

### 4.2 SecureStorage — DPAPI 加密键值存储

```
存储路径: {StorageDir}/{sanitized_key}.dat
加密方式: ProtectedData.Protect(DataProtectionScope.CurrentUser)
附加熵:   Encoding.UTF8.GetBytes("MeetingQ:{key}")
```

支持的 Key（`SecureStorageKeys` 常量类）：
| Key | 用途 |
|-----|------|
| `user_name` | 用户姓名（逗号分隔） |
| `user_nicknames` | 昵称 |
| `user_asr_variants` | ASR 同音误识词 |
| `user_role` | 角色标签 |
| `llm_profiles` | LLM 配置 JSON 数组 |
| `capture_window_title` | 截图目标窗口标题 |
| `mic_enabled` | 麦克风是否启用 |
| `mic_device_name` | 麦克风设备名 |
| `privacy_accepted` | 隐私声明已接受 |

### 4.3 StorageConfig — 可迁移数据目录

- 默认目录：`%APPDATA%\MeetingQ`
- 指针文件：`%LOCALAPPDATA%\MeetingQ\storage_path.txt`（只存目录路径）
- `SetStorageDir(path)`: 写入指针文件
- `MigrateData(src, dst)`: 复制所有 `*.dat` 到新目录
- 目录不可访问时自动回退到默认目录

### 4.4 LlmProfileStore

```csharp
Load()          → SecureStorage.Load(Key) → JsonSerializer.Deserialize<List<LlmProfile>>
Save(profiles)  → JsonSerializer.Serialize → SecureStorage.Save(Key)
GetActive()     → Load().FirstOrDefault(p => p.IsActive)
```

### 4.5 SingleInstanceGuard

```
机制:
  1. 命名 Mutex "MeetingQ_SingleInstance_v2" 检测重复
  2. 第一实例启动 NamedPipeServerStream "MeetingQ_Activation_v2"
  3. 第二实例连接 pipe → 第一实例收到激活信号 → 调用 onActivationRequested
  4. 第二实例立即退出
```

### 4.6 NativeTrayIcon — Win32 系统托盘

```
实现:
  - Shell_NotifyIcon (NIM_ADD / NIM_MODIFY / NIM_DELETE)
  - 消息窗口 HwndSource (HWND_MESSAGE) 接收回调
  - CALLBACK_MSG = WM_APP + 1
  - 双击 WM_LBUTTONDBLCLK → DoubleClick 事件
  - 右击 WM_RBUTTONUP → WPF ContextMenu (SetForegroundWindow + Placement)
  - Explorer 重启时 (TaskbarCreated) 自动重建图标
```

### 4.7 PinyinHelper — 拼音模糊匹配

- 内置 ~600 个常见姓名用字的音调无关拼音映射表
- `GetPinyin(char)`: 单字 → 拼音
- `SamePronunciation(a, b)`: 两字符串拼音全同判断
- `FindPinyinMatch(name, text)`: 滑动窗口查找同音匹配
- **自动补充 ASR 变体**: 当发现新的同音匹配时自动写入 `user_asr_variants` 并重建 regex

---

## 5. Services 层

### 5.1 AudioCaptureService — 音频采集

```
输入:    系统扬声器 (WASAPI Loopback) + 可选麦克风
输出:    PCM16, 16kHz, mono (每帧 3200 bytes = 100ms)
处理链:  WASAPI → BufferedWaveProvider → IEEE Float 转换 → StereoToMono → WdlResamplingSampleProvider(16kHz)
          → 可选麦克风混入 (TwoChannelMixer, 各 50% 衰减) → SampleToWaveProvider16

VAD:     内联能量检测（非 VadProcessor 类 — VAD 在类内以 RMS 计算代替）
         静音阈值 < 0.01 RMS 用于统计，不阻止数据流。

数据流:  每 100ms 读取一帧 → AudioDataAvailable 事件 + 直接推送到 ASR (SetAsr)
统计:   每秒 RMS 峰值, 每 30s 管道统计 (fps/字节/静音比例)
ASR dump: 可选写入 .wav 文件用于调试
```

### 5.2 SherpaOnnxAsrService — 本地 ASR（sherpa-onnx）

```
推理方式:  进程内 ONNX Runtime（org.k2fsa.sherpa.onnx NuGet），无网络请求
模型:      assets/models/ 随安装包内置（single-file 自解压到 models/）
           AsrModelManager 解析顺序: %LocalAppData% 已下载 → 随包内置 → 联网兜底下载

实时识别:
  - 流式 Paraformer（中英双语 int8，原生输出中文标点）
  - 端点断句: Rule2 尾随静音 1.2s 成句 (isFinal=true)；Rule3 20s 强制截断长独白
  - 滚动 partial (isFinal=false) + 定稿 final 双轨事件

说话人识别（实时级）:
  - 每句定稿时对当句音频提 ERes2Net embedding（3D-Speaker 中文模型）
  - OnlineSpeakerCluster 余弦相似度在线质心聚类（阈值 0.60）→ "发言人N"
  - 短句（<0.8s）embedding 不可靠 → 沿用上一句说话人

说话人识别（会后修正级）:
  - 会议期间全量录音到 %LocalAppData%\MeetingQ\recordings\meeting-{ts}.wav
  - EndSessionAsync 中对录音跑离线 diarization（pyannote segmentation 3.0 int8
    + ERes2Net embedding + FastClustering，阈值 0.5；OCR 到"N 人参会"时约束聚类数）
  - 按时间戳对齐（补偿 1.2s 端点提交延迟）把离线聚类映射回在线标签（多数投票），
    纠正实时误标后批量落库；随后再走截图 OCR 的实名映射
  - 成功后删除录音文件（音频不长期留存）

说话人实名映射（三级，精度递增）:
  1. 实时: 说话人时间线（每次定稿记录 时间+标签）→ 截图/Vision/OCR 拿到名字时
     按"截图时刻在说话的人"投票；新标签首票即映射，其余需 2 票防 OCR 误识别；
     映射成立立即回填 DB 中该标签的历史记录
  2. 会后语音段对齐: 截图显示"张三 正在发言"的时刻 → 离线 diarization 该时刻
     语音段 → 所在 cluster → 对应在线标签，得票（1.5x 明确胜出才映射）
  3. 会后时间距离投票: MapSpeakerLabelsToNames ±60s 加权投票（兜底）

线程模型:
  - SendAudioAsync 仅入队（Channel），专用后台任务做 PCM16→float、送识别、发事件
  - FinalizeSegmentAsync: 入队 flush 控制项 → 当前句定稿提交（本地模型持续运行，无重连）
```

### 5.3 ConfigurableLlmService — OpenAI 兼容 LLM

```
接口:        ILlmService
HTTP 客户端: 静态单例，Timeout = InfiniteTimeSpan（由调用方 CTS 控制）
端点:        {BaseUrl}/chat/completions
认证:        Bearer {ApiKey}
请求体:
  {
    "model": "{ModelId}",
    "messages": [
      { "role": "system", "content": "…" },
      { "role": "user", "content": "…" }
    ],
    "max_tokens": 2048
  }

AnalyzeAsync(prompt):           system="你是会议助手，请简洁准确地回答。"
SummarizeAsync(transcripts):     system="你是会议纪要助手…" prompt="请分析以下会议转录内容…JSON 格式返回…"
TestAsync():                     system="You are a helpful assistant.", user="Reply with exactly: ok"

错误处理: HttpRequestException / TaskCanceledException / SocketException → 中文友好错误消息
```

### 5.4 ScreenCaptureService — 周期截图

```
间隔:         8 秒轮询（变化才去重保存，保存冷却 5 秒）
静音节流:     ShouldSkipPeriodicCapture — 会议静音 >30s 时暂停周期截图
              （无人说话时共享内容大概率不变；按需截图不受影响）
保存路径:     %LOCALAPPDATA%\MeetingQ\Screenshots\screenshot_{timestamp}.jpg
截图方式:
  - IntPtr.Zero: Graphics.CopyFromScreen (主屏幕) + BitBlt 回退
  - 非零 HWND:  PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT) 获取指定窗口
      失败回退到全屏截图

去重机制:
  - 每次截图生成 64×36 缩略图
  - 计算像素 MD5: MD5.HashData(pixels)
  - 与上次 hash 相同 → 跳过保存

触发式截图:
  - 新说话人首次出现（10s 冷却，防止交替发言连拍）
  - 被叫姓名时

JPEG 质量: 85%
首次截图: 启动时立即截取（不计入去重）
按需截图: TakeScreenshotAsync() — 绕过去重，始终保存
```

### 5.4a LocalOcrService — WinRT 本地 OCR

```
引擎:      Windows.Media.Ocr（系统内置，中文 zh-Hans-CN 优先，>3900px 自动降采样）
零成本:    无网络、无模型下载，100-300ms/张
用途:
  1. 无 Vision 模式: 每张截图 OCR → OcrText 落库（AnalysisStatus=ready），
     供会后名字映射与会议纪要使用
  2. 说话人名提取: "张三 正在发言"/"李四(发言中)" 等模式正则 → 参与实时投票
  3. 参会人数信号: "N 人参会" → 会后聚类 num_clusters 约束
  4. Vision 未识别到发言人时的降级兜底
```

### 5.5 NameDetectionService — 3 层姓名检测

```
层 0 (<50ms):  本地正则匹配 + 拼音模糊匹配
  - Regex: 用户姓名/昵称/ASR变体 → | 分隔的编译正则 (IgnoreCase)
  - Pinyin: 滑动窗口 n-gram pinyin 同音匹配
  - 命中后自动将匹配词追加到 ASR 变体列表 → ReloadNames()

层 1 (<200ms): 中文疑问/指向性模式
  - 疑问尾词: 吗/呢/么/嘛/啊
  - 疑问词:   什么/怎么/为什么/哪里/哪个/哪些/谁/多少/几/如何/是否
  - 指向短语: 你觉得/你认为/你说/你来/你有/你能/请你/问你/想问你/你的意见/你的看法…

层 2 (1–3s):   LLM 语义分析
  - 给出用户姓名/昵称/角色 → 判断是否指向该用户 → 提取子问题
  - 返回: {"directed":true/false, "questions":["问题1"]}
  - 层 2 失败时回退到层 1 结果

检测触发: 仅在 isFinal=true 的完整句子上运行（避免并发 LLM 请求洪水）
冷却时间: 弹窗触发 5 秒冷却
```

### 5.6 VadProcessor — 能量 VAD

```
状态机: Silence → Speech → Trailing → Silence
参数:
  - SpeechThreshold:  0.005 RMS
  - SilenceThreshold: 0.003 RMS
  - PreRollFrames:    200ms (10 帧)
  - PostRollFrames:   300ms (15 帧)
  - MinSpeechFrames:  150ms (8 帧)
  - 每帧: 20ms @ 16kHz PCM16 = 640 bytes

行为:
  - Silence: 维护 pre-roll 环形队列
  - Speech:  累积帧
  - Trailing: 累积帧，若 RMS 回升 → 回 Speech；若静音超过 post-roll → 发射
  - Flush(): 强制发射当前段（结束时调用）

诊断: 每秒 log 一次 peak RMS
```

### 5.7 SelfTestAudio — 自检 TTS

```
使用 System.Speech.Synthesis.SpeechSynthesizer
优先中文语音 (zh-CN): "会议助手功能自检，一二三，四五六，语音识别测试完成。"
回退英文:             "Meeting Mind self test. One two three…"
参数: Rate=-2 (稍慢), Volume=85
```

---

## 6. ViewModels

### 6.1 FloatingWindowViewModel — 核心业务逻辑

#### 状态属性

```csharp
bool   IsMonitoring          // 是否正在监听
bool   IsSelfTestRunning     // 功能自检运行中
bool   IsManualAlertRunning  // 手动提醒运行中
string CurrentTopic          // 当前议题
string LatestTranscript      // 最新转写文本（最近 25 条 + 当前部分）
string ElapsedTime           // 已运行时长
string StatusText            // 状态文本
bool   HasSessionData        // 是否有会话数据
string CaptureWindowTitle    // 截图目标窗口标题
string InlineSummaryText     // 行内摘要
bool   IsInlineSummaryLoading
string SelfTestResult        // 自检结果
bool   SelfTestPassed        // 自检通过
ObservableCollection<string>      AvailableWindows      // 可用窗口列表
ObservableCollection<DiagnosticItem> DiagnosticSteps     // 诊断步骤
bool   IsDiagnosticVisible
string DiagnosticHint        // 诊断提示
```

#### 命令

| 命令 | 说明 |
|------|------|
| `StartListeningAsync` | 启动监听（含诊断流程） |
| `StopListeningAsync` | 停止监听 |
| `ToggleDiagnostics` | 展开/收起诊断面板 |
| `RunSelfTestAsync` | 8 步功能自检 |
| `ManualTriggerAlertAsync` | 手动触发被叫提醒 |
| `ShowQuickSummaryAsync` | 显示快速摘要弹窗 |
| `OpenScreenshotAlbum` | 打开截图时光轴 |
| `RefreshWindows` | 刷新可用窗口列表 |

#### 监听启动流程

```
1. 检查 LLM 配置 (是否有 Active profile)
2. 检查截图窗口是否存在 (否则弹出窗口选择器)
3. ResetDiagnostics() → IsDiagnosticVisible = true
4. Step 1: 音频设备检测 (AudioCaptureService.StartAsync)
5. Step 2: ASR 初始化 (SherpaOnnxAsrService.ConnectAsync — 加载本地模型)
6. Step 3: 监听音频信号 (10s 超时检测静音)
7. Step 4: 监听转录结果 (30s 超时检测无转录)
8. 启动 ASR 看门狗 (每 5s 检查冻结)
9. 启动行内摘要定时器 (每 5 分钟)
10. 创建 DB 会话 + 初始议题
11. 启动截图服务 (30s 间隔)
12. 启动计时器
```

#### ASR 看门狗（两种冻结检测）

```
Case A (显示解冻，不重置):
  10s 无识别更新 + 音频活跃 (RMS > 0.003) → 清除 _lastAsrText
  (不中断识别流 — 模型会在说话暂停后自然提交完整句子)

Case B (真正冻结，强制定稿):
  30s 无任何 transcript → FinalizeSegmentAsync (flush 当前句)
```

#### 转录处理流程

```
OnTranscriptReceived:
  1. 若是自检模式 → 完成 TCS
  2. 句子边界检测:
     - isFinal=true: 直接提交（确定句）
     - isFinal=false: 推测边界（uid变化 / 长度重置 > 50%）
  3. 提交的句子: 追加到历史 → 持久化到 SQLite → 更新看门狗时间戳
  4. 显示: 最后 25 条 + 当前部分文本
  5. 仅对 isFinal 句子运行姓名检测
  6. 每 20 条转录 → 触发 LLM 议题检测
  7. 每 25 条转录 → 触发 LLM 结论/行动项检测
```

#### 议题检测

```
每 20 条转录触发 (单线程防重入)
Prompt: "根据以下会议对话，用不超过10个字总结当前讨论的核心议题"
结果: 更新 CurrentTopic 属性 + 标题 → 触发 TopicFlash 动画 + 更新 DB
```

#### 结论检测

```
每 25 条转录触发 (单线程防重入)
Prompt: "提取决策结论和行动项，JSON 返回"
结果: 去重合并到 _currentDecisions / _currentActionItems
      每条表最多: 50 条决策, 30 条行动项
      持久化到 SQLite
```

#### 快速摘要

```
获取最近 100 条转录 → LLM 生成 JSON (summary + decisions + actions)
结果显示在 QuickSummaryPopup + InlineSummaryText
自动合并检测到的决策和行动项到内存和 DB
```

#### 姓名检测触发

```
每次 isFinal 句子 → 异步运行 NameDetectionService.DetectAsync
命中后:
  - 5 秒冷却检查
  - 更新 DB 中转录的 Speaker 字段
  - 获取前 8 条上下文
  - 拍即时截图 (TakeScreenshotAsync)
  - 触发 NameDetected 事件 → NameAlertPopup 弹窗
```

### 6.2 SettingsViewModel

#### 个人身份 Tab

```csharp
string UserName         // 姓名（逗号分隔）
string UserNicknames    // 昵称
string UserAsrVariants  // ASR 同音变体
string UserRole         // 角色标签
```

#### 大模型 Tab

```csharp
ObservableCollection<LlmProfileItem> LlmProfiles   // 可编辑列表
LlmProfileItem?                     SelectedProfile // 当前选中
ObservableCollection<string>         AvailableModels // 获取的模型列表

// 命令
AddProfile()         // 添加新配置
DeleteProfile()      // 删除选中配置
SetActiveProfile()   // 设为当前激活
FetchModelsAsync()   // GET {baseUrl}/models 获取模型列表
TestConnectionAsync()// 测试 LLM 连接（超时 15s）
TestAsrConnectionAsync() // 测试 ASR 连接（超时 30s）
```

#### 语音识别 Tab

```csharp
bool   MicEnabled     // 是否启用麦克风采集
string MicDeviceName  // 麦克风设备选择
```

#### 使用统计 Tab

```csharp
string StatsSessions    // 会议次数
string StatsTotalTime   // 累计时长
string StatsTranscripts // 转录条数
string StatsScreenshots // 截图张数
bool   StatsLoading
```

#### 其他功能

```csharp
GenerateAsrVariantsAsync()  // LLM 生成 ASR 同音变体（60s 超时）
BrowseDataDirectory()       // 选择数据目录
MigrateDataDirectory()      // 迁移数据到新目录
ClearAllConfig()            // 清空所有配置
ClearTranscriptHistory()    // 清空转录历史
ClearScreenshotHistory()    // 清空截图历史+文件
SaveSettings()              // 保存所有配置
```

#### LlmProfileItem

```csharp
partial class LlmProfileItem : ObservableObject
{
    Guid   Id;
    string Name;
    string BaseUrl;
    string ApiKey;
    string ModelId;
    bool   IsActive;

    LlmProfile ToModel()               // 转换为存储模型
    static LlmProfileItem FromModel(p)  // 从存储模型创建
}
```

### 6.3 HistoryViewModel

#### 数据结构

```csharp
// SessionItem — 列表 + 详情
class SessionItem
{
    int    SessionId;
    string Title;              // "会议 MM-dd" 或自定义
    DateTime StartTime;
    DateTime? EndTime;
    int    TranscriptCount;    // 懒加载
    int    ScreenshotCount;
    string DateLabel;          // "yyyy年MM月dd日  HH:mm"
    string DurationLabel;      // "Xh Ym" or "Xm Ys"
    List<string>           TopicTitles;        // 议题名称列表
    List<TranscriptItem>   Transcripts;        // 懒加载
    List<ScreenshotItem>   ScreenshotPaths;    // 初始已加载
    List<string>           Decisions;          // 懒加载
    List<ActionItemDisplay> ActionItems;       // 懒加载
}

class TranscriptItem   { DateTime Timestamp; string TimeLabel; string? Speaker; string Text; }
class ActionItemDisplay { string AssignedTo; string Task; string? Deadline; string Label; }
```

#### 加载策略

```
初始加载: 仅加载 Sessions + Topics + Screenshots + 转录计数
         (不加载 Transcript/Decision 详情，避免笛卡尔积)
详情加载: 用户选中会议时 → LoadDetailAsync (AsSplitQuery)
标记已加载: _loadedIds 防止重复请求
取消: 切换选择时 Cancel 正在加载的详情
筛选: 搜索文本过滤标题/议题
```

#### 导出功能

| 格式 | 内容 |
|------|------|
| Markdown (.md) | 会议时间线（转录+截图按时间交错），议题，决策表格，行动项表格，截图副本到 `_files/` |
| HTML (.html) | 带 CSS 样式，截图以 Base64 Data URI 内嵌，响应式布局 |
| 纯文本 (.txt) | 仅转录，格式：`[时间] 说话人：文本` |

### 6.4 ScreenshotAlbumViewModel

```csharp
ObservableCollection<ScreenshotItem> Screenshots; // 缩略图列表
ScreenshotItem? SelectedScreenshot;               // 选中项
BitmapSource?   SelectedImage;                    // 选中项的原图（懒加载）

AddScreenshot(filePath, timestamp) // 缩略图异步加载 → UI 线程添加
Clear()                            // 清空所有
```

### 6.5 DiagnosticItem

```csharp
enum DiagState { Pending, Running, OK, Warning, Error }

class DiagnosticItem : ObservableObject
{
    string    Name;      // "音频设备", "ASR 连接" ...
    DiagState State;     // Pending/Running/OK/Warning/Error
    string    Detail;    // 详情文本

    // 线程安全的 setter（自动 Marshal 到 UI 线程）
    SetPending(); SetRunning(detail); SetOk(detail); SetWarning(detail); SetError(detail);

    // 计算属性: Icon ("○"/"⟳"/"✓"/"⚠"/"✕"), IconColor, DetailColor
}
```

---

## 7. Views (WPF XAML)

### 7.1 FloatingWindow — 主窗口

```
尺寸: 320×440 (Min 260×340)
外观: WindowStyle=None, 圆角 12, 投影, 白色背景
布局 (8 行):
  Row 0: Title Bar (44px)
    - Ellipse (监控状态指示点: 灰/绿/紫)
    - "MeetingQ" 标题
    - 按钮组: 自检状态◉/ 历史📋/ 设置⚙/ 隐藏▾
  Row 1: Status Strip (26px)
    - 状态指示灯 + StatusText + ElapsedTime
  Row 2: Window Picker (Auto, 监控时隐藏)
    - ComboBox(可编辑) + 刷新按钮
  Row 3: Diagnostic Panel (Auto, 可折叠)
    - 诊断步骤列表 (ItemsControl)
    - 自检结果 Badge (绿/红色)
    - 诊断提示 (黄色警告框)
  Row 4: Topic Display (Auto)
    - 议题标题 (带动画高亮 flash)
  Row 5: Transcript (*)
    - 滚动文本区域
  Row 6: Inline Summary (Auto, 有条件显示)
  Row 7: Bottom Bar (44px)
    - 📷 截图 / ⚡ 摘要 / 🔔 被叫到 / 功能自检 / 开始/停止 按钮

关键交互:
  - 开始/停止按钮: Pill 样式，通过 DataTrigger 切换颜色/命令
  - Window Picker: 自动展开下拉 (WindowSelectionRequired 事件)
  - 议题变更: Storyboard "TopicFlash" 动画 (1.2s 渐隐)
  - Transcript: PropertyChanged 自动滚到底部
  - 关闭: MinimizeToTray (不是真正关闭)
```

### 7.2 SettingsWindow — 设置窗口

```
尺寸: 660×620, 固定大小, CenterOwner
Tab 页:
  1. 个人身份
     - 姓名/昵称/ASR变体 (+ 🤖 生成)/角色 输入框
     - 数据存储目录 (浏览/打开/迁移)
  2. 大模型
     - 左侧: 配置列表 (ListBox + Add/Delete)
     - 右侧: 编辑表单 (Name/BaseUrl/ApiKey/ModelId + 获取模型列表)
     - 激活状态+设为当前
  3. 语音识别
     - 本地 ASR 信息卡片（sherpa-onnx 离线转写 + 说话人识别）
     - 麦克风采集开关 (自定义 Toggle) + 设备选择
  4. 使用统计
     - 4 个统计卡片 (会议次数/累计时长/转录条数/截图张数)
     - 清空数据按钮

底部栏:
  - 清空配置 / 收集日志 / 测试 ASR / 测试 LLM / 保存设置
```

### 7.3 NameAlertPopup — 被叫姓名提醒弹窗

```
尺寸: Width=420, SizeToContent=Height, MaxHeight=540
外观: Topmost, 无标题栏, 透明背景, 圆角+投影
定位: 右下角 (PositionBottomRight)

内容:
  - Header: 黄色背景 "[X]秒前有人叫你!" + 📌固定/✕关闭
  - 📸 被叫时截图 (可点击放大 → 全屏 Lightbox)
  - 原话 (黄色引文框)
  - 📍 需要你回答的问题 (编号列表 ❶ ❷ ❸)
  - 📋 前后上下文 (最近 8 条，分隔线下方)
  - ✅ 我知道了 按钮

Pin 功能: 固定后新提醒不覆盖（新弹窗并列显示）
```

### 7.4 QuickSummaryPopup — 快速摘要弹窗

```
尺寸: 480×560, Topmost, 可拖拽
内容:
  - Skeleton 状态: 加载中（3 条灰色占位线）
  - Content 状态: 议题名称 / 要点摘要 / 决策列表 / 行动项列表
底部栏: 🔄 刷新 / 📋 复制摘要 / 关闭
快捷键: ESC 关闭
```

### 7.5 ScreenshotAlbumWindow — 截图时光轴

```
尺寸: 720×520 (Min 480×360)
5 行布局:
  Row 0: Title Bar (📷 截图时光轴 + 张数 + ✕)
  Row 1: 预览区 (空状态 / 选中截图原图)
  Row 2: 时间戳信息栏
  Row 3: 分隔线
  Row 4: 水平缩略图条 (ListBox, VirtualizingStackPanel horizontal, 120px 宽缩略图)
```

### 7.6 HistoryWindow — 历史会议

```
尺寸: 780×540 (Min 560×380)
左右分栏:
  左侧 (230px):
    - 标题 "历史会议"
    - 搜索框 (按标题/议题筛选)
    - 会话列表 (标题/议题/转录数/截图/日期)
    - 状态栏
  右侧 (*):
    - 空状态: "选择一条会议记录"
    - 详情 (ScrollViewer):
      - 标题 + 元信息（日期·时长·转录数）
      - 议题标签
      - 截图缩略图 (WrapPanel, 点击放大 Lightbox)
      - 决策列表
      - 行动项列表
      - 转录记录 (时间-说话人-文本)
    - 底部操作栏: 导出 .md / 导出 .html / 导出 .txt / 删除

数据加载:
  - 窗口打开时加载列表 (仅元数据)
  - 选择会话时懒加载详情 (AsSplitQuery)
  - 已加载的会话缓存，切换时不重新请求
```

### 7.7 PrivacyNoticeWindow — 首次隐私声明

```
尺寸: 480×420, CenterScreen
内容: 📡 网络请求 / 💾 本地存储 / 🎤 采集范围 说明
按钮: "我已阅读，开始使用" → SecureStorage.Save(PrivacyAccepted, true) → DialogResult = true
```

---

## 8. App.xaml.cs — 应用生命周期

```
OnStartup:
  1. 注册全局异常处理 (AppDomain + Dispatcher)
  2. AppLog.Initialize()
  3. ShutdownMode = OnExplicitShutdown (托盘模式)
  4. DEBUG: AllocConsole() — 输出控制台
  5. SingleInstanceGuard 检查 → 已有实例则激活前置并退出
  6. 构建 Generic Host:
     - DbContext (SQLite)
     - Services (AudioCapture, ASR, LLM, ScreenCapture, NameDetection)
     - ViewModels (Singleton/Transient)
     - Views (Singleton/Transient)
  7. 启动 Host
  8. 应用 EF 迁移 (失败则 EnsureDeleted + 重建)
  9. 启用 SQLite WAL + synchronous=NORMAL
  10. 首次运行隐私声明
  11. 显示 FloatingWindow
  12. 启动单实例激活监听
  13. 创建系统托盘图标 + 菜单
  14. 首次运行且无 LLM 配置 → 打开设置窗口

OnExit:
  1. 清理托盘图标
  2. 同步停止 Host (3s 超时)
  3. Environment.Exit(0) — 强制终止残留线程

托盘菜单:
  - 显示主窗口
  - 历史会议…
  - 设置…
  - 打开日志目录
  - ────
  - 退出 MeetingQ
```

---

## 9. 数据流总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        MeetingQ 数据流                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [系统扬声器]                                                    │
│       │ WASAPI Loopback                                          │
│       ▼                                                          │
│  ┌─────────────────┐    100ms PCM16 frames    ┌───────────────┐ │
│  │ AudioCapture    │ ───────────────────────→ │ SherpaOnnx    │ │
│  │ Service         │    (直接 SetAsr 推送)     │ AsrService    │ │
│  │ (16kHz/mono)    │                          │ (本地推理)    │ │
│  └─────────────────┘                          └───────┬───────┘ │
│                                                       │         │
│                                          TranscriptReceived     │
│                                                       │         │
│                                                       ▼         │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              FloatingWindowViewModel                       │  │
│  │                                                           │  │
│  │  1. isFinal=true → 提交到 _transcriptHistory              │  │
│  │  2. 持久化到 SQLite (Transcript)                          │  │
│  │  3. 更新 LatestTranscript 显示                            │  │
│  │  4. isFinal → NameDetectionService.DetectAsync            │  │
│  │  5. 每20条 → DetectTopicAsync (LLM)                       │  │
│  │  6. 每25条 → DetectConclusionsAsync (LLM)                 │  │
│  └───────────────────────────────────────────────────────────┘  │
│       │                 │              │               │         │
│       ▼                 ▼              ▼               ▼         │
│  [SQLite DB]    [NameAlert]    [QuickSummary]  [Topic Update]   │
│                                                       │         │
│  ┌─────────────────┐                                  │         │
│  │ ScreenCapture   │  8s poll + silence skip             │         │
│  │ Service         │ ──────────→ [Screenshots dir]   │         │
│  │ (MD5 去重)      │                                  │         │
│  └─────────────────┘                                  │         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 10. 构建与部署

### 发布命令

```bash
dotnet publish -r win-x64 -c Release --self-contained false
```

输出目录: `src/MeetingQ/bin/Release/net8.0-windows10.0.17763.0/win-x64/publish/`

### 安装包

使用 Inno Setup 6.x 构建 `.iss` 脚本，特性：
- .NET 8 Desktop Runtime 前置检查
- 64 位安装
- 可选的桌面快捷方式和开机启动
- 中英文语言支持
- 卸载时保留用户数据

### 系统要求

- Windows 10 1809+ / Windows 11
- .NET 8 Desktop Runtime (x64)
- 支持 WASAPI Loopback 的音频驱动

---

## 11. 关键技术决策

1. **不使用 `H.NotifyIcon`**: 其异步 ImageSource→HICON 管道在运行时失败，采用原始 Win32 Shell_NotifyIcon P/Invoke。

2. **HTTP 客户端不设超时**: `ConfigurableLlmService` 的 HttpClient.Timeout 设 InfiniteTimeSpan，由调用方 CancellationToken 控制超时，避免 Windows 上 HttpClient.Timeout 与 CTS 竞态导致 SocketException 995。

3. **EF Core AsSplitQuery**: 历史窗口加载详情时必须使用 `AsSplitQuery()`，否则 EF 的 `Include` 链会产生 Topics×Transcripts×Decisions×ActionItems 笛卡尔积。

4. **ASR 看门狗双模式**: Case A（显示解冻，不重连）优先保护服务器声学上下文，避免重连导致丢词；Case B（真正冻结时才重连）兜底。

5. **仅 isFinal 句子上运行 LLM 检测**: streaming partial 更新频率极高（~300ms/字），逐帧 LLM 请求会导致并发洪水。只在确定句上运行姓名检测和结论提取。

6. **截图去重使用 MD5**: 64×36 缩略图 MD5 对分辨率不敏感，能检测有意义的画面变化。内存占用小，计算快。

7. **DPAPI 加密存储**: API Key 等敏感数据不写明文，使用 Windows DPAPI (CurrentUser scope)，无法跨机器解密。

8. **拼音模糊匹配自动学习**: 层 0 拼音匹配发现新的 ASR 同音词后自动写入 `user_asr_variants`，后续走精确 regex 快速路径。
