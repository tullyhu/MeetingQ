# 会议自动检测规格说明（W5）

<!-- doc-covers: Sources/MeetingQ/Services/MeetingWatcherService.swift, Sources/MeetingQ/Services/AudioProcessInspector.swift, Sources/MeetingQ/Services/WindowListHelper.swift (windowExists), Sources/MeetingQ/Services/ActiveSpeakerAxService.swift (hasCallControls) -->
<!-- doc-verified: initial -->

面向"纯听会"场景设计：不依赖日历、不做内容分析，
只回答一个问题——**该不该替你按下开始/停止**。

## 证据模型

| 证据 | 来源 | 角色 |
|---|---|---|
| 候选窗口 | CGWindowList 标题/owner + 内置会议 App 档案（数据驱动表） | 候选生成 |
| 浏览器 URL | AX 读取聚焦窗口 AXURL，匹配会议域名 pattern | 浏览器候选生成 |
| 输出占用 | CoreAudio process object `IsRunningOutput` | **开始主证据 / 结束软证据** |
| 输入占用 | `IsRunning` | 仅开始加速（一次即可确认） |
| 通话控件 | AX 遍历找 静音+挂断 按钮 | 仅开始加速 |
| 窗口销毁 | 原始窗口列表（无尺寸过滤、含屏外）按 CGWindowID 查 | **唯一硬结束证据** |

设计要点：会议 App 整场会议都持有输出（静音的听众也在收声），纯听会场景全覆盖；
输入占用在纯听会时为零，所以**绝不用于结束判定**。

## 状态机

```
idle → confirming（同一候选连续命中 2 次；输入/控件命中 1 次即确认）
     → inMeeting → [A 软结束] 输出释放 60s → 提示条确认（不自动停）
                 → [B 硬结束] 窗口销毁 → 自动停止采集 + 提示看纪要
任何停止后 → cooldown 10 分钟（不与用户手动停止对抗）
```

轮询：固定 5s。

## 编号边界 case

开始判定：

- **S1** 候选窗口存在 且 输出占用连续 2 次轮询命中 → 确认开始
- **S2** 候选 + 输入占用 或 通话控件 → 1 次即确认（加速通道）
- **S3** 浏览器：必须有 URL pattern 命中，否则不算候选（防止看视频误触发）
- **S4** 未知 App 同时持有输入+输出 → 每日最多提示一次"识别为会议软件吗？"，确认后写入学习列表
- **S5** corespeechd 等系统常驻音频进程必须排除；avconferenced 不排除（它是系统通话的音频引擎，会议期间同样持有音频输出）
- **S6** 手动停止后 10 分钟内不重新检测同一会话

结束判定：

- **E1** 窗口缩小成小窗/最小化 → CGWindowID 仍在 → 不算结束
- **E2** 浏览器 tab 关闭但窗口还在 → 走 A 类软提示，不硬结束
- **E3** 窗口真正销毁（CGWindowID 查不到）→ 硬结束：自动停止采集、生成纪要提示
- **E4** 输出释放 < 60s（网络抖动/暂时静音播放）→ 不动作
- **E5** 软结束提示每场会议最多一次；用户选"继续监听"后不再提示

模式：

- **M1** 三档：自动开始 / 仅提示（默认）/ 关闭
- **M2** 已在监听时检测到新会议 → 不切换（单会议假设，砍掉了多会议室切换）

## 测试要求

- S1/S2 确认次数逻辑、E1 窗口存在性（含屏外）、E4 宽限计时
- S5 排除清单命中
- 冷却期 S6
