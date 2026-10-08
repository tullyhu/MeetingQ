# MeetingQ for Windows

MeetingQ 的 Windows 版本 —— WPF (.NET 8) 桌面会议助手：本地实时转写（sherpa-onnx 离线 Paraformer）、声纹说话人识别、被叫姓名提醒、AI 会议纪要。

## 构建

要求：Windows 10 1809+ x64（开发机）· .NET 8 SDK · Inno Setup 6（可选，仅做安装包需要）

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
