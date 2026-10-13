// MeetingQ - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 MeetingQ contributors
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

import MeetingQCore
import SwiftUI

public struct SettingsView: View {
    private enum SettingsPane: String, CaseIterable, Identifiable {
        case general, identity, llm, speech, stats
        public var id: String { rawValue }
    }

    @State private var vm: SettingsViewModel
    @State private var selectedPane: SettingsPane = .general
    @State private var showClearConfigConfirm = false
    @State private var showClearTranscriptsConfirm = false
    @State private var showClearScreenshotsConfirm = false

    @MainActor public init(vm: SettingsViewModel? = nil) {
        _vm = State(initialValue: vm ?? SettingsViewModel())
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsPane.allCases, selection: $selectedPane) { pane in
                    Label(paneTitle(pane), systemImage: paneIcon(pane))
                        .tag(pane)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
            } detail: {
                paneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 620)
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

    // MARK: - Panes

    private func paneTitle(_ pane: SettingsPane) -> String {
        switch pane {
        case .general: return tr("通用", "General")
        case .identity: return tr("个人身份", "Identity")
        case .llm: return tr("大模型", "LLM")
        case .speech: return tr("语音识别", "Speech")
        case .stats: return tr("使用统计", "Stats")
        }
    }

    private func paneIcon(_ pane: SettingsPane) -> String {
        switch pane {
        case .general: return "gearshape"
        case .identity: return "person.crop.circle"
        case .llm: return "brain"
        case .speech: return "waveform"
        case .stats: return "chart.bar"
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general: generalTab
        case .identity: identityTab
        case .llm: llmTab
        case .speech: asrTab
        case .stats: statsTab
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

            Section {
                LabeledContent(tr("辅助功能权限", "Accessibility Permission")) {
                    if vm.accessibilityGranted {
                        Text(tr("已授权", "Granted"))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(tr("去授权", "Grant Access")) { vm.requestAccessibilityPermission() }
                    }
                }
            } header: {
                Text(tr("发言人识别", "Speaker Detection"))
            } footer: {
                Text(tr("授权后可直接从会议软件的界面元素读取「正在发言」的人名，比截图识别更快更准；未授权时自动回退到截图识别。",
                        "Once granted, the app reads the active speaker's name directly from the meeting app's UI — faster and more accurate than screenshot recognition. Without it, screenshot recognition is used as fallback."))
            }

            Section {
                Picker(tr("会议自动检测", "Meeting Auto-Detection"), selection: Binding(
                    get: { MeetingWatcherService.shared.mode },
                    set: { MeetingWatcherService.shared.setMode($0) })) {
                    ForEach(MeetingWatcherService.Mode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text(tr("会议自动检测", "Meeting Auto-Detection"))
            } footer: {
                Text(tr("通过候选窗口与音频输出占用识别会议开始。检测到时自动选择会议窗口；「仅提示」会先询问，「自动开始」直接开始监听。窗口真正销毁才会自动结束，疑似散会只会提示确认。",
                        "Detects meeting starts via candidate windows and audio-output usage. On detection it auto-selects the meeting window; \"Prompt Only\" asks first, \"Auto Start\" begins listening immediately. Only actual window destruction ends capture automatically — a suspected end always asks."))
            }

            Section {
                Toggle(tr("说话人分离（Beta）", "Speaker Diarization (Beta)"), isOn: Binding(
                    get: { vm.speakerDiarizationEnabled },
                    set: { vm.setSpeakerDiarizationEnabled($0) }))
                    .disabled(vm.diarizationModelDownloading)
                if vm.speakerDiarizationEnabled {
                    Toggle(tr("实时显示「对方1/对方2」", "Show \"Speaker 1/2\" live"), isOn: Binding(
                        get: { vm.speakerLiveLabelsEnabled },
                        set: { vm.setSpeakerLiveLabelsEnabled($0) }))
                }
                if vm.diarizationModelDownloading {
                    ProgressView(value: vm.diarizationModelProgress)
                }
                if !vm.diarizationModelStatus.isEmpty {
                    Text(vm.diarizationModelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("说话人分离", "Speaker Diarization"))
            } footer: {
                Text(tr("使用设备端声纹模型把「对方」细分为多个说话人，首次开启需下载约 15MB 模型，全程离线运行。效果因会议环境而异，关闭后完全回到原有表现。",
                        "Uses an on-device voiceprint model to split \"Remote\" into individual speakers. First enable downloads ~15MB of models; everything runs offline. Results vary by meeting environment; turning it off fully restores previous behavior."))
            }

            Section {
                if vm.voiceprints.isEmpty {
                    Text(tr("暂无声纹记录。开启说话人分离并完成会议后，识别到的声音会出现在这里。",
                            "No voiceprints yet. With diarization enabled, voices recognized in meetings will appear here."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.voiceprints, id: \.id) { sp in
                        HStack(spacing: 8) {
                            Text(vm.displayName(for: sp))
                                .fontWeight(sp.isNamed ? .regular : .medium)
                            if sp.isManuallyNamed {
                                Text(tr("手动", "manual")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(tr("\(sp.embeddingCount) 个样本", "\(sp.embeddingCount) samples"))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(tr("改名", "Rename")) {
                                vm.renamingVoiceprintId = sp.id
                                vm.renamingVoiceprintName = sp.name ?? ""
                            }
                            Menu(tr("合并到…", "Merge into…")) {
                                ForEach(vm.voiceprints.filter { $0.id != sp.id }, id: \.id) { target in
                                    Button(vm.displayName(for: target)) {
                                        vm.mergeVoiceprints(targetId: target.id, sourceId: sp.id)
                                    }
                                }
                            }
                            .disabled(vm.voiceprints.count < 2)
                            Button(tr("删除", "Delete"), role: .destructive) { vm.deleteVoiceprint(id: sp.id) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(vm.confirmClearVoiceprints
                               ? tr("再次点击确认清空", "Click again to confirm")
                               : tr("清空全部声纹", "Clear All Voiceprints"), role: .destructive) {
                            if vm.confirmClearVoiceprints {
                                vm.clearAllVoiceprints()
                                vm.confirmClearVoiceprints = false
                            } else {
                                vm.confirmClearVoiceprints = true
                            }
                        }
                    }
                }
            } header: {
                Text(tr("声纹库", "Voiceprint Library"))
            } footer: {
                Text(tr("声纹是无法还原为语音的数学特征向量，仅保存在本机。改名后，下次会议中该人的发言会直接显示真名。",
                        "A voiceprint is a mathematical feature vector that cannot be turned back into audio and is stored on this machine only. Renamed voices show their real name in future meetings."))
            }

            Section {
                Link(tr("隐私政策", "Privacy Policy"),
                     destination: URL(string: "https://meetingq-privacy.tully-hu.workers.dev/macos/")!)
                Link(tr("开源致谢", "Open Source Acknowledgements"),
                     destination: URL(string: "https://github.com/tullyhu/MeetingQ/blob/main/ACKNOWLEDGEMENTS.md")!)
            } header: {
                Text(tr("关于", "About"))
            }
        }
        .formStyle(.grouped)
        .alert(tr("重命名声纹", "Rename Voiceprint"), isPresented: Binding(
            get: { vm.renamingVoiceprintId != nil },
            set: { if !$0 { vm.renamingVoiceprintId = nil } })) {
            TextField(tr("真实姓名", "Real name"), text: $vm.renamingVoiceprintName)
            Button(tr("保存", "Save")) {
                if let id = vm.renamingVoiceprintId { vm.renameVoiceprint(id: id, to: vm.renamingVoiceprintName) }
                vm.renamingVoiceprintId = nil
            }
            Button(tr("取消", "Cancel"), role: .cancel) { vm.renamingVoiceprintId = nil }
        } message: {
            Text(tr("下次会议中该人的发言将直接显示这个名字。",
                    "This person's speech will show this name in future meetings."))
        }
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
                            Text(p.provider == .apple ? tr("Apple 系统模型", "Apple System Model") : p.modelId)
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
                Picker(tr("服务商", "Provider"), selection: $profile.provider) {
                    Text(tr("OpenAI 兼容接口", "OpenAI Compatible")).tag(LlmProvider.openAICompatible)
                    Text(tr("Apple 系统模型", "Apple System Model")).tag(LlmProvider.apple)
                        .disabled(!vm.appleAvailability.isAvailable)
                }
                if !vm.appleAvailability.isAvailable && profile.provider != .apple {
                    Text(vm.appleAvailability.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if profile.provider == .apple && !vm.appleAvailability.isAvailable {
                    Label(tr("当前系统模型不可用：\(vm.appleAvailability.message)", "Apple system model unavailable: \(vm.appleAvailability.message)"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(tr("服务商", "Provider"))
            } footer: {
                if profile.provider == .apple {
                    Text(tr("使用 macOS 内置的端侧模型，无需 API Key，数据不出本机。不支持截图图片分析（将自动使用本地 OCR）。",
                            "Uses the on-device model built into macOS. No API Key needed; data never leaves this Mac. Image analysis is not supported (local OCR will be used automatically)."))
                }
            }

            if profile.provider == .openAICompatible {
            Section {
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
