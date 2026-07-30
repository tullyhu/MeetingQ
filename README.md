# CalledMe

**中文** | [English](README_EN.md)

**开会时被叫到名字，它第一时间提醒你。** —— macOS 原生 AI 会议助手：本地实时转写 · 被叫即时提醒 · 图文会议记录 · 可完全离线运行

<p>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-15%2B-black">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.10-orange">
  <img alt="Dependencies" src="https://img.shields.io/badge/dependencies-0-brightgreen">
  <img alt="License" src="https://img.shields.io/badge/license-GPLv3-blue">
</p>

![CalledMe 浮动窗](docs/screenshots/01-floating-window.png)

---

## 为什么做 CalledMe

开线上会议时你有没有过这种经历：一边"听会"一边回消息，突然听到有人叫你的名字——"张伟，这个方案你怎么看？" 而你完全不知道前面聊了什么。

CalledMe 就是为这一刻而生的：

1. **它一直在听** —— 系统音频实时转写成文字，全程在你的 Mac 本地完成
2. **它认得你** —— 有人叫到你名字（包括同音误读），0.5 秒内弹窗提醒
3. **它帮你补上下文** —— 弹窗里附上被叫瞬间的截图、原话、前后 8 条对话，以及 AI 提取出的"对方抛给你的问题"
4. **它把纪要也写了** —— 散会后一键生成摘要、决策、行动项，导出 Markdown / HTML / TXT

## 效果演示

| 被叫姓名提醒 | AI 快速摘要 |
|:---:|:---:|
| ![被叫提醒](docs/screenshots/02-name-alert.png) | ![快速摘要](docs/screenshots/03-quick-summary.png) |
| 弹窗 + 即时截图 + 上下文 + 问题提取 | 要点 / 决策 / 行动项一键生成 |

| 实时转写浮动窗 | 历史会议与导出 |
|:---:|:---:|
| ![浮动窗](docs/screenshots/01-floating-window.png) | ![历史会议](docs/screenshots/04-history.png) |
| 议题自动跟踪，转写实时滚动 | 完整存档，三种格式导出 |

## 功能特性

### 🎙️ 实时语音转写（100% 设备端）
- macOS 26 使用全新的 `SpeechAnalyzer / SpeechTranscriber` 框架，macOS 15–25 自动回退到设备端 `SFSpeechRecognizer`
- 原始音频**永远不离开你的 Mac**，无需联网、无识别额度限制
- 中英文双语界面，识别语言随界面切换

### 🗣️ 双轨发言人识别
- **麦克风轨与系统音轨独立转写**：你的发言 100% 准确归属（显示为你的名字），远程参会者归入"对方"轨——不依赖任何声纹模型，物理声道隔离天然不会标错
- **会末自动命名**：结合截图 OCR 识别出的"正在发言"人名，按时间戳做距离加权投票为"对方"命名；仅当证据明确收敛时才替换，多人远程会议宁可保留"对方"也不张冠李戴
- 浮动窗与会议纪要中按发言人分段展示，谁说了什么一目了然

### 🔔 被叫姓名提醒（核心功能）
三层检测管道，兼顾速度与准确率：

| 层级 | 技术 | 耗时 | 作用 |
|------|------|------|------|
| 0 | 本地正则 + 拼音模糊匹配 | <50ms | 精确命中姓名/昵称/同音误读 |
| 1 | 中文疑问句/指向性模式 | <200ms | "你觉得呢"、"你来负责"等 |
| 2 | LLM 语义分析 | 1-3s | 结合你的姓名/角色判断是否在叫你，并提取具体问题 |

命中后：弹窗提醒（可置顶固定）→ 拍即时截图 → 展示原话 + 前后 8 条上下文 + AI 提取的待回答问题。拼音匹配发现的同音误读会**自动学习**，下次走快速通道。

### 🧠 AI 会议纪要（本地或云端，你说了算）
- **本地大模型优先**：为大内存 Apple Silicon Mac 设计，直接连接本机 oMLX 等 OpenAI 兼容服务——零 API 费用、全离线、数据零出机
- **推荐 Qwen3.6 系列多模态大模型**：文字 + 图像联合理解，既能读转写文本，又能"看懂"截图里的幻灯片、图表、代码和发言人，产出**理解更深的会议纪要**——不只是"谁说了什么"，还有"屏幕上展示了什么、数据说明了什么"
- **云端自由切换**：同样支持 DeepSeek、通义、Kimi、OpenAI 等任意 OpenAI 兼容接口
- 议题自动检测（每 20 条转写）、决策与行动项自动提炼、随时手动生成快速摘要

### 📸 自动截图与视觉分析
- 每 30 秒自动截图（64×36 缩略图 MD5 去重，画面不变不存）
- 多模态大模型可解读截图内容：识别图表/文档/代码，甚至识别视频会议 UI 中**正在发言的人名**
- 截图时光轴：按时间浏览会议全程画面

### 🔒 隐私与安全
- **不录制会议音视频**：音频仅在内存中实时流转用于识别，转写完成后即丢弃；本软件不会生成或保存任何会议录音、录像文件，本地只保留文字转写与截图
- 语音识别 100% 设备端；搭配本地 LLM 可实现**全链路离线**
- 所有数据（转写/截图/纪要）仅存本地 SQLite（WAL 模式）
- API Key 存于 macOS 系统钥匙串（`WhenUnlockedThisDeviceOnly`）
- 正式签名构建以应用沙盒（App Sandbox）运行，仅申请必要权限（本地自签名构建为免钥匙串重复授权提示会关闭沙盒）
- 首次启动展示隐私声明与录音合规提示
- **零日志**：应用不写任何日志文件（源码中已移除整个日志系统），无遥测、无统计、无广告、无崩溃上报

### 🛠️ 其他
- 中英文双语界面，首次启动选择语言
- 四步漫游引导：授权 → 填写姓名 → 配置模型 → 上手
- 8 步功能自检：一键诊断音频采集、识别、转写全链路
- 菜单栏常驻 + 可拖动浮动小窗，单实例运行

## 快速开始

### 方式一：下载 DMG（推荐）

从 [Releases](../../releases) 下载 `CalledMe-x.x.x.dmg`，拖入 Applications 即可。

> 未公证的应用首次打开如遇拦截：右键 App →「打开」→ 在弹窗中确认。

### 方式二：源码构建

```bash
git clone https://github.com/tullyhu/CalledMe.git
cd CalledMe

# 编译并打包 .app（输出 dist/CalledMe.app）
./scripts/bundle.sh

# 生成 DMG
VERSION=1.0.0 ./scripts/package-dmg.sh
```

**要求**：运行需 macOS 15+ · Apple Silicon；编译需 Xcode 26+ 或 Command Line Tools（macOS 26 SDK，无需任何第三方依赖，纯 `swiftc` 编译）

### 首次使用（漫游引导会带你走完）

1. **选择语言**（中文 / English）
2. **阅读隐私声明**
3. **授权**：语音识别 + 屏幕录制（采集系统音频与截图所需）+ 麦克风（可选）
4. **填写姓名/昵称** —— 被叫提醒就靠它
5. **配置 AI 模型**：
   - 本地推荐：安装 [oMLX](https://github.com/jundot/omlx)（基于 Apple MLX 框架的本地大模型运行时，`brew install omlx` 或下载 DMG），加载 **Qwen3.6 系列多模态模型**（同时胜任文本摘要与截图视觉理解），接口地址 `http://localhost:8000/v1`，Key 留空
   - 云端示例：DeepSeek `https://api.deepseek.com/v1` + 你的 API Key
6. 开会前点击浮动窗的 **「开始监听」**，然后专心开会（或者专心摸鱼，CalledMe 帮你盯着）

## 使用指南

### 浮动窗口
- **开始/停止监听**：底部胶囊按钮。启动时会自动执行 4 步诊断（音频设备 → ASR 连接 → 信号检测 → 转写检测）
- **议题栏**：LLM 每 20 条转写自动更新当前议题，变化时高亮闪烁
- **📷 按钮**：立即截图（绕过去重）
- **⚡ 按钮**：基于最近 100 条转写生成快速摘要
- **🔔 按钮**：手动触发一次被叫提醒（测试用）
- **↺ 按钮**：清空当前转写显示（需确认，不影响已保存的会议记录）
- **功能自检**：播放一段测试语音，验证「采集 → 识别 → 转写」全链路是否正常

### 被叫提醒弹窗
- **📌 固定**：重要提醒钉在屏幕上，新提醒并列显示不覆盖
- **点击截图**：全屏放大查看被叫瞬间的画面
- **❶❷❸ 问题列表**：AI 提取的对方抛给你的问题，照着回答即可
- **✅ 我知道了**：确认并关闭（5 秒冷却，避免连续打扰）

### 历史会议
- 左侧列表搜索（按标题/议题），右侧查看完整详情
- 导出格式：
  - **Markdown**：时间线（转写+截图交错）+ 议题 + 决策/行动项表格，截图复制到 `_files/`
  - **HTML**：带样式，截图 Base64 内嵌，单文件可直接分享
  - **TXT**：纯转写文本

### 数据位置

| 内容 | 位置 |
|------|------|
| 数据库 / 截图 | `~/Library/Application Support/CalledMe/` |
| API Key / 配置 | macOS 钥匙串（service: CalledMe） |

## 技术栈

| 层级 | 技术 |
|------|------|
| UI | SwiftUI + AppKit（菜单栏 / 浮动窗 / 弹窗） |
| 语音识别 | Speech framework（macOS 26+ SpeechAnalyzer，15–25 回退 SFSpeechRecognizer；设备端，随界面语言切换中英） |
| 音频采集 | ScreenCaptureKit 系统音频 + AVAudioEngine 麦克风（双轨独立转写） |
| 截图 | ScreenCaptureKit，64×36 缩略图 MD5 去重 |
| LLM | 任意 OpenAI 兼容 API（本地 oMLX / 云端均可） |
| 视觉分析 | 多模态 LLM（OCR / 图表理解 / 发言人识别） |
| 姓名检测 | 正则 + 拼音模糊匹配（内置 ~600 字表，自动学习变体）+ LLM 语义 |
| 存储 | SQLite3 (WAL) + macOS Keychain |
| 构建 | 纯 `swiftc`，零第三方依赖 |

## 项目结构

```
CalledMe/
├── Package.swift
├── LICENSE
├── Resources/
│   ├── Info.plist                # Bundle 配置、权限声明、ATS 本地网络
│   ├── CalledMe.entitlements     # App Sandbox / 网络 / 麦克风
│   └── AppIcon.icns
├── scripts/
│   ├── bundle.sh                 # 编译 + 打包 .app + 签名（支持 entitlements）
│   └── package-dmg.sh            # 生成 DMG + 可选公证
└── Sources/CalledMe/
    ├── App/                      # 入口、启动流程（语言选择→隐私→引导→主窗）
    ├── Models/                   # 会话/议题/转写/截图/决策/行动项
    ├── Infrastructure/           # 本地化、SQLite、钥匙串、拼音匹配、单实例、菜单栏
    ├── Services/                 # 音频采集、语音转写、LLM、截图、视觉、姓名检测、VAD
    ├── ViewModels/               # 浮动窗/设置/历史/截图相册/诊断
    └── Views/                    # SwiftUI 界面、引导、弹窗
```

## 隐私承诺

- ❌ 无账号系统、无遥测、无 Crash 上报、无任何自家服务器
- ✅ 语音识别全程设备端，原始音频不出机
- ✅ 只有你主动配置的 LLM 端点会收到转写文本/截图（配置本地模型则完全离线）
- ✅ 全部代码开源，欢迎审计

**合规提醒**：录制会议可能涉及其他参会人权益，请遵守所在地录音相关法规，必要时事先征得同意。

## FAQ

**Q: 为什么需要屏幕录制权限？**
A: macOS 采集"系统播放的声音"（即会议对方的声音）必须经由 ScreenCaptureKit，而该 API 要求屏幕录制权限。截图功能同样依赖它。CalledMe 不会在你未开始监听时读取任何屏幕/音频数据。

**Q: 支持 Intel Mac 吗？**
A: 不支持。本地大模型与设备端识别依赖 Apple Silicon。运行要求 macOS 15+：macOS 15–25 使用设备端 `SFSpeechRecognizer`，macOS 26+ 使用新的 `SpeechAnalyzer` 框架。

**Q: 转写准确率如何？**
A: 取决于 Apple 设备端语音模型，中文普通话清晰语音下表现良好。姓名识别可通过"ASR 同音变体"持续优化。

**Q: 本地模型选哪个？**
A: 推荐 **Qwen3.6 系列多模态大模型**——一个模型同时覆盖文本摘要、议题检测与截图视觉理解（图表/OCR/发言人识别）。32GB+ 内存可选更大的参数量版本，16GB 机型选小参数版本即可。纯文本场景也可用 `qwen3` 文本系列，但会失去截图理解能力。

**Q: CalledMe 会保存会议录音或录像吗？**
A: 不会。音频只在内存中实时送交设备端识别，转写后即丢弃；应用不生成任何音视频文件。本地仅保存文字转写、摘要与定时截图（截图可在设置中清空）。

## 贡献

Issue 和 PR 欢迎。提交前请运行 `./scripts/bundle.sh` 确认编译通过。

## License

[GPLv3](LICENSE) — 你可以自由使用、修改和分发本软件，但衍生作品必须以相同协议开源。

