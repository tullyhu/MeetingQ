// CalledMe - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 CalledMe contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

public struct SettingsView: View {
    @State private var vm: SettingsViewModel
    @State private var showClearConfigConfirm = false
    @State private var showClearTranscriptsConfirm = false
    @State private var showClearScreenshotsConfirm = false

    @MainActor public init(vm: SettingsViewModel? = nil) {
        _vm = State(initialValue: vm ?? SettingsViewModel())
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }
                identityTab
                    .tabItem { Label(tr("个人身份", "Identity"), systemImage: "person.crop.circle") }
                llmTab
                    .tabItem { Label(tr("大模型", "LLM"), systemImage: "brain") }
                asrTab
                    .tabItem { Label(tr("语音识别", "Speech"), systemImage: "waveform") }
                statsTab
                    .tabItem { Label(tr("使用统计", "Stats"), systemImage: "chart.bar") }
            }
            Divider()
            bottomBar
        }
        .frame(width: 640, height: 600)
        .task { vm.loadStats() }
        .confirmationDialog(tr("确定要清空所有配置吗？", "Clear all configuration?"),
                            isPresented: $showClearConfigConfirm,
                            titleVisibility: .visible) {
            Button(tr("清空配置", "Clear Configuration"), role: .destructive) { vm.clearAllConfig() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("这将删除：姓名、API Key、大模型配置等所有设置。\n会议记录（数据库）不受影响。",
                    "This will delete all settings including your name, API Key, and LLM configuration.\nMeeting records (database) are not affected."))
        }
        .confirmationDialog(tr("确定要清空所有转录历史吗？", "Clear all transcript history?"),
                            isPresented: $showClearTranscriptsConfirm,
                            titleVisibility: .visible) {
            Button(tr("清空转录历史", "Clear Transcript History"), role: .destructive) { vm.clearTranscriptHistory() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("这将删除数据库中所有会议的转录文本记录。\n截图不受影响。",
                    "This will delete all transcript records from the database.\nScreenshots are not affected."))
        }
        .confirmationDialog(tr("确定要清空所有截图历史吗？", "Clear all screenshot history?"),
                            isPresented: $showClearScreenshotsConfirm,
                            titleVisibility: .visible) {
            Button(tr("清空截图历史", "Clear Screenshot History"), role: .destructive) { vm.clearScreenshotHistory() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("这将删除数据库记录并删除磁盘上的截图文件，此操作不可撤销。",
                    "This will delete database records and screenshot files on disk. This cannot be undone."))
        }
    }

    // MARK: - Tab 0: 通用

    private var generalTab: some View {
        Form {
            Section {
                Toggle(tr("在 Dock 中显示图标", "Show Dock Icon"), isOn: $vm.showDockIcon)
            } header: {
                Text(tr("程序坞", "Dock"))
            } footer: {
                Text(tr("开启后应用图标会显示在 Dock 中；关闭后仅保留菜单栏图标。",
                        "When enabled, the app icon appears in the Dock; when disabled, only the menu bar icon remains."))
            }

            Section {
                Picker(tr("截图分析方式", "Screenshot Analysis"), selection: $vm.screenshotAnalysisEngine) {
                    Text(tr("多模态大模型", "Multimodal LLM")).tag("llm")
                    Text(tr("本地 OCR（离线）", "On-device OCR (offline)")).tag("local_ocr")
                }
                Toggle(tr("多模态失败时本地 OCR 兜底", "Local OCR fallback when multimodal fails"), isOn: $vm.localOcrFallbackEnabled)
                    .disabled(vm.screenshotAnalysisEngine == "local_ocr")
            } header: {
                Text(tr("多模态", "Multimodal"))
            } footer: {
                if vm.screenshotAnalysisEngine == "local_ocr" {
                    Text(tr("纯本地 OCR 模式不使用大模型、完全离线，但没有内容摘要、图表理解和发言人识别能力。",
                            "On-device OCR mode never calls the LLM and works fully offline, but provides no content summary, chart understanding, or speaker detection."))
                } else {
                    Text(tr("多模态大模型分析截图失败时，使用 macOS 本地 OCR 提取图中文字，识别全程离线。",
                            "When multimodal LLM analysis fails, use macOS on-device OCR to extract text from screenshots. Fully offline."))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 1: 个人身份

    private var identityTab: some View {
        Form {
            Section {
                TextField(tr("姓名", "Name"), text: $vm.userName)
                TextField(tr("昵称（逗号分隔）", "Nicknames (comma-separated)"), text: $vm.userNicknames)
                LabeledContent(tr("ASR同音变体", "ASR Variants")) {
                    HStack(spacing: 6) {
                        TextField(tr("逗号分隔", "comma-separated"), text: $vm.userAsrVariants)
                        Button(vm.isGeneratingAsrVariants ? tr("生成中…", "Generating…") : tr("AI 生成", "Generate")) {
                            vm.generateAsrVariants()
                        }
                        .disabled(!vm.canGenerateAsrVariants)
                    }
                }
                TextField(tr("角色标签（可选）", "Role Tag (optional)"), text: $vm.userRole)
            } header: {
                Text(tr("名字检测", "Name Detection"))
            } footer: {
                if vm.hasAsrVariantsError {
                    Text(vm.asrVariantsError)
                        .foregroundStyle(.red)
                } else {
                    Text(tr("软件在转录文本中匹配你的姓名 / 昵称。若 ASR 将名字误识别成同音词，填入同音变体即可触发提醒。「AI 生成」可自动推断可能的同音误识词。",
                            "The app matches your name / nicknames in the transcript. If the ASR misrecognizes your name as a homophone, add the variant to trigger alerts. \"Generate\" lets AI infer possible misrecognitions."))
                }
            }

            Section {
                LabeledContent(tr("当前目录", "Directory")) {
                    HStack(spacing: 6) {
                        TextField("", text: $vm.dataDirectory)
                            .font(.callout.monospaced())
                        Button(tr("浏览…", "Browse…")) { vm.browseDataDirectory() }
                        Button(tr("打开", "Open")) { vm.openDataDirectory() }
                    }
                }
                Button(tr("迁移现有数据到新目录", "Migrate Existing Data to New Directory")) { vm.migrateDataDirectory() }
            } header: {
                Text(tr("数据存储目录", "Data Storage"))
            } footer: {
                Text(tr("配置文件和数据存储在此目录，仅保存在本机。更改后点「保存设置」生效；建议先「迁移」再保存，否则旧数据仍在原目录。",
                        "Configuration and data are stored in this directory on this machine only. Changes take effect after \"Save Settings\". Migrate first, then save, or old data stays in the original directory."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 2: 大模型

    private var llmTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $vm.selectedProfileId) {
                    ForEach(vm.llmProfiles) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(p.isActive ? Color.green : Color.clear)
                                    .frame(width: 6, height: 6)
                                Text(p.name.isEmpty ? tr("（未命名）", "(Untitled)") : p.name)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                            Text(p.modelId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                                .lineLimit(1)
                        }
                        .tag(p.id)
                    }
                }
                HStack(spacing: 4) {
                    Button(action: { vm.addProfile() }) {
                        Image(systemName: "plus")
                    }
                    .help(tr("添加配置", "Add Profile"))
                    Button(action: { vm.deleteProfile() }) {
                        Image(systemName: "minus")
                    }
                    .disabled(!vm.hasSelectedProfile)
                    .help(tr("删除配置", "Delete Profile"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 180)

            Divider()

            ScrollView {
                if let profile = vm.selectedProfile {
                    ProfileEditForm(profile: profile, vm: vm)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                } else {
                    ContentUnavailableView {
                        Label(tr("未选择配置", "No Profile Selected"), systemImage: "brain")
                    } description: {
                        Text(tr("选择或添加一个大模型配置", "Select or add an LLM profile"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
        }
    }

    // MARK: - Tab 3: 语音识别

    private var asrTab: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("本地语音识别（设备端）", "On-Device Speech Recognition"))
                        Text(tr("使用 macOS 设备端语音识别，音频不出本机，首次使用自动下载模型",
                                "Uses macOS on-device speech recognition. Audio never leaves this Mac; the model downloads automatically on first use."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Section {
                Toggle(tr("启用麦克风采集", "Enable Microphone Capture"), isOn: $vm.micEnabled)
                if vm.micEnabled {
                    TextField(tr("麦克风设备（留空为默认）", "Microphone (empty = default)"), text: $vm.micDeviceName)
                }
            } header: {
                Text(tr("麦克风采集（混音）", "Microphone Capture (Mixing)"))
            } footer: {
                Text(tr("开启后麦克风输入与系统音频混合送入 ASR，适合本地说话也需被识别的场景。",
                        "When enabled, microphone input is mixed with system audio into the ASR. Useful when your own speech also needs to be recognized."))
            }

            Section {
                Button(tr("测试 ASR", "Test ASR")) { vm.testAsrConnection() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 4: 使用统计

    private var statsTab: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    statCard(title: tr("会议次数", "Meetings"), value: vm.statsSessions, symbol: "calendar")
                    statCard(title: tr("累计时长", "Total Time"), value: vm.statsTotalTime, symbol: "clock")
                    statCard(title: tr("转录条数", "Transcripts"), value: vm.statsTranscripts, symbol: "text.quote")
                    statCard(title: tr("截图张数", "Screenshots"), value: vm.statsScreenshots, symbol: "photo.on.rectangle")
                }
                .redacted(reason: vm.statsLoading ? .placeholder : [])
            } header: {
                Text(tr("本机使用统计", "Local Usage Stats"))
            } footer: {
                Text(tr("以下数据来自本地数据库，不上传至任何服务器。",
                        "The following data comes from the local database and is never uploaded."))
            }

            Section {
                Button(tr("清空转录历史…", "Clear Transcript History…"), role: .destructive) {
                    showClearTranscriptsConfirm = true
                }
                Button(tr("清空截图历史…", "Clear Screenshot History…"), role: .destructive) {
                    showClearScreenshotsConfirm = true
                }
            } header: {
                Text(tr("清空数据", "Clear Data"))
            } footer: {
                Text(tr("清空截图历史将同时删除磁盘上的图片文件，此操作不可撤销。",
                        "Clearing screenshot history also deletes image files on disk. This cannot be undone."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button(tr("清空配置…", "Clear Configuration…")) { showClearConfigConfirm = true }
                .font(.caption)
                .foregroundStyle(.secondary)
            if !vm.dataDirStatus.isEmpty {
                Text(vm.dataDirStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if vm.hasAsrTestResult {
                Label(vm.asrTestResult, systemImage: vm.asrTestResult.contains(tr("成功", "successful")) ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(vm.asrTestResult.contains(tr("成功", "successful")) ? Color.green : Color.secondary)
                    .lineLimit(1)
            }
            if vm.hasConnectionTestResult {
                Label(vm.connectionTestResult, systemImage: vm.connectionTestResult.contains(tr("成功", "successful")) ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(vm.connectionTestResult.contains(tr("成功", "successful")) ? Color.green : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(tr("测试 LLM", "Test LLM")) { vm.testConnection() }
            Button(tr("保存设置", "Save")) {
                vm.saveSettings()
                WindowRouter.closeSettings()
            }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func statCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .mmSectionHeader()
            Text(value)
                .font(.title2.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mmCard(padding: 10)
    }
}

private struct ProfileEditForm: View {
    @Bindable var profile: LlmProfileItem
    let vm: SettingsViewModel

    var body: some View {
        Form {
            Section {
                TextField(tr("配置名称", "Profile Name"), text: $profile.name)
                TextField(tr("接口地址（Base URL）", "Base URL"), text: $profile.baseUrl)
                SecureField("API Key", text: $profile.apiKey)
                LabeledContent(tr("模型 ID", "Model ID")) {
                    HStack(spacing: 6) {
                        modelPicker(selection: $profile.modelId)
                        Button(vm.isFetchingModels ? tr("获取中…", "Fetching…") : tr("获取列表", "Fetch")) { vm.fetchModels() }
                            .disabled(!vm.canFetchModels)
                    }
                }
            } header: {
                Text(tr("接口配置", "Connection"))
            } footer: {
                Text(tr("示例：https://api.openai.com/v1 — API Key 以本机硬件密钥加密存储，不会明文落盘",
                        "e.g. https://api.openai.com/v1 — API keys are encrypted with a machine-bound key, never written to disk in plain text"))
            }

            Section {
                modelPicker(selection: $profile.visionModelId)
            } header: {
                Text(tr("Vision 模型 ID（可选）", "Vision Model ID (optional)"))
            } footer: {
                Text(tr("多模态截图分析用。留空则复用 Model ID。",
                        "Used for multimodal screenshot analysis. Leave empty to reuse Model ID."))
            }

            Section {
                modelPicker(selection: $profile.compressionModelId)
            } header: {
                Text(tr("压缩模型 ID（可选）", "Compression Model ID (optional)"))
            } footer: {
                Text(tr("长会议上下文压缩用，可用速度较快的轻量模型。留空则复用 Model ID。",
                        "Used to compress long meeting history; a fast lightweight model works well. Leave empty to reuse Model ID."))
            }

            Section {
                LabeledContent {
                    Button(tr("设为当前使用", "Set as Active")) { vm.setActiveProfile() }
                        .disabled(profile.isActive)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(profile.isActive ? Color.green : Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 6, height: 6)
                        Text(profile.isActive ? tr("当前使用中", "Active") : tr("未激活", "Inactive"))
                    }
                }
                Button(tr("测试 LLM 连接", "Test LLM Connection")) { vm.testConnection() }
            } footer: {
                Text(tr("启动监听时将自动测试当前使用的接口。",
                        "The active connection is tested automatically when listening starts."))
            }
        }
        .formStyle(.grouped)
    }

    private func modelPicker(selection: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField("", text: selection)
            if !vm.availableModels.isEmpty {
                Menu {
                    ForEach(vm.availableModels, id: \.self) { m in
                        Button(m) { selection.wrappedValue = m }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}
