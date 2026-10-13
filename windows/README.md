# MeetingQ for Windows

MeetingQ 的 Windows 版本 —— WPF (.NET 8) 桌面会议助手：本地实时转写（sherpa-onnx 离线 Paraformer）、声纹说话人识别、被叫姓名提醒、AI 会议纪要。

## v1.8.0 新特性（与 macOS 版对齐）

- **声纹时长门控聚类**：<1s 跳过 / 1–2s 只匹配 / ≥2s 学习，簇上限 6，单簇会议不沉淀（避免污染声纹库）
- **声纹库**：跨会议持久化（SQLite），设置页可改名 / 勾选合并 / 删除 / 二次确认清空；改名后的老熟人在下次会议**实时显示真名**
- **会议自动检测**：通过音频会话输出占用 + 候选窗口识别会议开始（Zoom / 腾讯会议 / 飞书 / 钉钉 / Teams / Webex，浏览器标题弱匹配）；三档模式（自动开始 / 仅提示（默认）/ 关闭）；托盘气泡提示、点击即确认；仅窗口真正销毁才自动结束，疑似散会只提示确认；手动停止后 10 分钟冷却
- **历史页问答 rail**：对整场会议直接提问（带建议问句，未配置 LLM / 无转录时区分提示）
- **单元测试**：`tests/MeetingQ.Tests`（xUnit，13 例，与 macOS 同 case 镜像）

详细移植差异见 [docs/port_parity_2026-10.md](docs/port_parity_2026-10.md)。

## 构建

要求：Windows 10 1809+ x64（开发机）· .NET 8 SDK · Inno Setup 6（可选，仅做安装包需要）。也可在 macOS/Linux 上交叉编译（csproj 已启用 `EnableWindowsTargeting`）。

```bash
# 还原 + 调试运行
dotnet build MeetingQ.sln

# 发布单文件 exe（含运行时与本地模型，约 470MB）
dotnet publish src/MeetingQ/MeetingQ.csproj -c Release -r win-x64 -o dist/publish-win

# 打 zip 便携包 / 生成安装包
# zip: 压缩 dist/publish-win/MeetingQ.exe 即可
# 安装包: 用 Inno Setup 编译 installer/MeetingQ.iss
```

## 模型文件

`assets/models/` 未包含在仓库中（约 265MB）。首次构建前请下载 sherpa-onnx 流式 Paraformer 中文模型与说话人识别模型放入该目录，并保持 `src/MeetingQ/MeetingQ.csproj` 中引用的目录结构。详见 [sherpa-onnx 文档](https://k2-fsa.github.io/sherpa/onnx/)。

## 与 macOS 版的关系

功能对齐 macOS 版（仓库根目录），差异详见 [clydris.com](https://clydris.com/#meetingq) 的能力对比表。核心差异：Windows 版使用 sherpa-onnx 本地推理（完全离线、模型内置），macOS 版使用 Apple Speech 设备端框架。

## License

与仓库根目录一致：[GPLv3](../LICENSE)。
