# Windows 版与 macOS 版对齐说明（2026-10 更新）

2026-10-14 追加（v1.8.0）：纪要模板库 / 模板推荐 / 质量评分 / 结构化纪要解析（`Services/MinutesTemplates.cs`、`TemplateRecommender.cs`、`MinutesQualityAssessor.cs`、`StructuredMinutes.cs`、`MeetingFeatureExtractor.cs`）与跨会议主题聚合（`Services/ThemeClassifier.cs` + `Models/MeetingTheme` + 迁移 `20261014000001_AddMinutesTemplatesAndThemes`）均按 macOS MeetingQCore 同文件逐行移植，阈值与权重完全一致。Windows 截图无 slide 级决策/日期抽取，`MeetingFeatures.Slide*Count` 恒为 0，推荐器按转写信号降级运行。散会管道统一走 `Services/MinutesPipeline.cs`（模板路径失败时回退旧版固定 schema 摘要）。

本次把 macOS 版 W 系列的以下能力移植到 Windows 版：

| 特性 | macOS 实现 | Windows 实现 | 差异 |
|---|---|---|---|
| 时长门控聚类（1s/2s、簇上限 6、单簇丢弃） | MeetingQCore/SpeakerClusterer | `Services/SpeakerClusterer.cs` | 逐行对齐，同一 spec |
| 声纹库（持久化/改名/合并/清空） | DataStore speakers 表 | `Models/VoiceprintSpeaker` + `VoiceprintLibraryService` + EF 迁移 | 单表 + BLOB 存质心 |
| 声纹库实时命中（0.75） | FloatingWindowViewModel | `SherpaOnnxAsrService.IdentifySpeaker` 内联 | — |
| 会末沉淀（≥2 簇才写库，R5） | endSession | `EndSessionAsync` → `ISpeakerRefinement.PersistVoiceprintsAsync` | 沿用现有 OCR 投票名 |
| 会议自动检测（W5） | CoreAudio process object 输出占用 | NAudio `AudioSessionManager` 会话状态（render/capture endpoint） | 语义等价 |
| 检测提示 | UNUserNotification 带按钮 | 托盘气泡（NativeTrayIcon NIF_INFO）+ 点击气泡=确认 | 无按钮，点击即确认 |
| 硬结束 | CGWindowID 销毁 | 进程退出 或 主窗口 HWND 销毁（最小化保留） | 最小化语义一致 |
| 问答 rail（W4） | SwiftUI MeetingChatRail | HistoryWindow 底部 rail + `HistoryViewModel.AskAboutMeetingAsync` | 高度持久化暂未做 |
| 单元测试 | Tests/MeetingQCoreTests (12) | `tests/MeetingQ.Tests` (xUnit, 13) | 同 case 镜像 |

## Windows 特有差异 / 注意

- **音频证据源**：`IAudioSessionManager2` 会话 Active 状态 ≈ macOS `IsRunningOutput`。
  输入会话（capture endpoint Active）仅作开始加速，绝不用于结束判定。
- **浏览器证据**：v1 用窗口标题弱匹配（`BrowserPatterns`）；UIA 地址栏读 URL 是后续增强项。
- **未知 App 教学**（macOS 有）：Windows v1 未做。
- **EF 迁移**：`20261013000001_AddVoiceprintSpeakers` 手写，未附 Designer/snapshot 更新；
  下次用 `dotnet ef migrations add` 前请先运行 `dotnet ef migrations script` 校验，必要时重新生成 snapshot。
- **构建验证**：本次改动在未安装 Windows SDK 的机器上完成，未经编译。
  请在 Windows 上 `dotnet build MeetingQ.sln && dotnet test` 验证后再发版。

## 阈值

与 macOS 一致且同样待实测标定：簇匹配 0.72、库归并/实时命中 0.75。
