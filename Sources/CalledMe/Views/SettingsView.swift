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
            header
            TabView {
                identityTab
                    .tabItem { Text(tr("个人身份", "Identity")) }
                llmTab
                    .tabItem { Text(tr("大模型", "LLM")) }
                asrTab
                    .tabItem { Text(tr("语音识别", "Speech Recognition")) }
                statsTab
                    .tabItem { Text(tr("使用统计", "Usage Stats")) }
            }
            Divider()
            bottomBar
        }
        .frame(width: 660, height: 620)
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

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x6366F1), Color(hex: 0x818CF8)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 8, height: 8)
            Text("CalledMe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x818CF8))
            Text(" /")
                .foregroundStyle(Color.secondary.opacity(0.4))
            Text(tr("  设置", "  Settings"))
                .font(.system(size: 14))
                .foregroundStyle(Color.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab 1: 个人身份

    private var identityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(tr("名字检测配置", "Name Detection"))
                fieldLabel(tr("姓名", "Name"))
                TextField("", text: $vm.userName)
                    .textFieldStyle(.roundedBorder)
                fieldLabel(tr("昵称（逗号分隔）", "Nicknames (comma-separated)"))
                TextField("", text: $vm.userNicknames)
                    .textFieldStyle(.roundedBorder)
                fieldLabel(tr("ASR同音变体（逗号分隔）", "ASR Homophone Variants (comma-separated)"))
                HStack(spacing: 6) {
                    TextField("", text: $vm.userAsrVariants)
                        .textFieldStyle(.roundedBorder)
                    Button(vm.isGeneratingAsrVariants ? tr("生成中…", "Generating…") : tr("🤖 生成", "🤖 Generate")) {
                        vm.generateAsrVariants()
                    }
                    .disabled(!vm.canGenerateAsrVariants)
                }
                if vm.hasAsrVariantsError {
                    Text(vm.asrVariantsError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xF87171))
                        .padding(.top, 4)
                }
                fieldLabel(tr("角色标签（可选）", "Role Tag (optional)"))
                TextField("", text: $vm.userRole)
                    .textFieldStyle(.roundedBorder)

                infoBox(tr("""
                软件在转录文本中匹配你的姓名 / 昵称。
                若 ASR 将名字误识别成同音词，填入同音变体即可触发提醒。
                点击"🤖 生成"让 AI 自动推断可能的同音误识词。
                """, """
                The app matches your name / nicknames in the transcript.
                If the ASR misrecognizes your name as a homophone, add the variant to trigger alerts.
                Click "🤖 Generate" to let AI infer possible misrecognitions.
                """))
                .padding(.top, 18)

                Divider().padding(.vertical, 18)

                sectionHeader(tr("数据存储目录", "Data Storage Directory"))
                infoBox(tr("配置文件和数据存储在此目录。可迁移到其他磁盘；数据仅保存在本机。",
                           "Configuration and data are stored in this directory. It can be migrated to another disk; data stays on this machine."))
                fieldLabel(tr("当前目录", "Current Directory"))
                HStack(spacing: 6) {
                    TextField("", text: $vm.dataDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button(tr("浏览...", "Browse...")) { vm.browseDataDirectory() }
                    Button(tr("打开", "Open")) { vm.openDataDirectory() }
                }
                Button(tr("迁移现有数据到新目录", "Migrate Existing Data to New Directory")) { vm.migrateDataDirectory() }
                    .padding(.top, 8)
                Text(tr("更改后点「保存设置」生效；建议先「迁移」再保存，否则旧数据仍在原目录",
                        "Changes take effect after clicking \"Save Settings\". Migrate first, then save, or old data stays in the original directory."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
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
                                    .fill(p.isActive ? Color(hex: 0x22C55E) : Color.clear)
                                    .frame(width: 6, height: 6)
                                Text(p.name.isEmpty ? tr("（未命名）", "(Untitled)") : p.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                            }
                            Text(p.modelId)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                                .lineLimit(1)
                        }
                        .tag(p.id)
                    }
                }
                HStack(spacing: 6) {
                    Button(tr("+ 添加", "+ Add")) { vm.addProfile() }
                    Button(tr("删除", "Delete")) { vm.deleteProfile() }
                        .disabled(!vm.hasSelectedProfile)
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 180)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                if let profile = vm.selectedProfile {
                    ProfileEditForm(profile: profile, vm: vm)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                } else {
                    Text(tr("← 选择或添加一个大模型配置", "← Select or add an LLM profile"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
        }
    }

    // MARK: - Tab 3: 语音识别

    private var asrTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("🖥")
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("本地语音识别（设备端）", "On-Device Speech Recognition"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(tr("使用 macOS 设备端语音识别，音频不出本机，首次使用自动下载模型",
                                "Uses macOS on-device speech recognition. Audio never leaves this Mac; the model downloads automatically on first use."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))

                Divider().padding(.vertical, 18)

                sectionHeader(tr("麦克风采集（混音）", "Microphone Capture (Mixing)"))
                infoBox(tr("开启后麦克风输入与系统音频混合送入 ASR，适合本地说话也需被识别的场景。",
                           "When enabled, microphone input is mixed with system audio into the ASR. Useful when your own speech also needs to be recognized."))
                    .padding(.bottom, 10)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("🎤 启用麦克风采集", "🎤 Enable Microphone Capture"))
                            .font(.system(size: 13))
                        Text(vm.micEnabled ? tr("当前已开启", "Currently On") : tr("当前已关闭", "Currently Off"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $vm.micEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

                if vm.micEnabled {
                    fieldLabel(tr("麦克风设备", "Microphone Device"))
                    TextField(tr("（默认麦克风）", "(Default Microphone)"), text: $vm.micDeviceName)
                        .textFieldStyle(.roundedBorder)
                }

                Button(tr("测试 ASR", "Test ASR")) { vm.testAsrConnection() }
                    .padding(.top, 14)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Tab 4: 使用统计

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(tr("本机使用统计", "Local Usage Stats"))
                infoBox(tr("以下数据来自本地数据库，不上传至任何服务器。",
                           "The following data comes from the local database and is never uploaded."))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    statCard(title: tr("会议次数", "Meetings"), value: vm.statsSessions, color: Color(hex: 0x818CF8))
                    statCard(title: tr("累计时长", "Total Time"), value: vm.statsTotalTime, color: Color(hex: 0x22C55E))
                    statCard(title: tr("转录条数", "Transcripts"), value: vm.statsTranscripts, color: Color(hex: 0x60A5FA))
                    statCard(title: tr("截图张数", "Screenshots"), value: vm.statsScreenshots, color: Color(hex: 0x34D399))
                }
                .padding(.top, 16)
                .redacted(reason: vm.statsLoading ? .placeholder : [])

                Divider().padding(.vertical, 18)

                sectionHeader(tr("清空数据", "Clear Data"))
                HStack(spacing: 12) {
                    Button(tr("🗑 清空转录历史", "🗑 Clear Transcript History")) { showClearTranscriptsConfirm = true }
                        .foregroundStyle(Color(hex: 0xF87171))
                        .frame(maxWidth: .infinity)
                    Button(tr("🗑 清空截图历史", "🗑 Clear Screenshot History")) { showClearScreenshotsConfirm = true }
                        .foregroundStyle(Color(hex: 0xF87171))
                        .frame(maxWidth: .infinity)
                }
                Text(tr("清空截图历史将同时删除磁盘上的图片文件，此操作不可撤销。",
                        "Clearing screenshot history also deletes image files on disk. This cannot be undone."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button(tr("清空配置", "Clear Configuration")) { showClearConfigConfirm = true }
                        .font(.system(size: 11))
                    if !vm.dataDirStatus.isEmpty {
                        Text(vm.dataDirStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !vm.statusMessage.isEmpty {
                        Text(vm.statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if vm.hasAsrTestResult {
                    Text("ASR  \(vm.asrTestResult)")
                        .font(.system(size: 11))
                        .foregroundStyle(vm.asrTestResult.contains(tr("成功", "successful")) ? Color(hex: 0x22C55E) : .secondary)
                }
                if vm.hasConnectionTestResult {
                    Text("LLM  \(vm.connectionTestResult)")
                        .font(.system(size: 11))
                        .foregroundStyle(vm.connectionTestResult.contains(tr("成功", "successful")) ? Color(hex: 0x22C55E) : .secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button(tr("测试 ASR", "Test ASR")) { vm.testAsrConnection() }
                Button(tr("测试 LLM", "Test LLM")) { vm.testConnection() }
                Button(tr("保存设置", "Save Settings")) { vm.saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0x6366F1))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: 0x818CF8))
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func infoBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

private struct ProfileEditForm: View {
    @Bindable var profile: LlmProfileItem
    let vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("接口配置", "Connection"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: 0x818CF8))
                .padding(.bottom, 6)

            label(tr("配置名称", "Profile Name"))
            TextField("", text: $profile.name)
                .textFieldStyle(.roundedBorder)

            label(tr("接口地址（Base URL）", "Base URL"))
            TextField("", text: $profile.baseUrl)
                .textFieldStyle(.roundedBorder)
            hint(tr("示例：https://api.openai.com/v1  /  https://dashscope.aliyuncs.com/compatible-mode/v1",
                    "e.g. https://api.openai.com/v1  /  https://dashscope.aliyuncs.com/compatible-mode/v1"))

            label("API Key")
            SecureField("", text: $profile.apiKey)
                .textFieldStyle(.roundedBorder)
            hint(tr("API Key 保存于 macOS 钥匙串，不会明文落盘",
                    "API Key is stored in the macOS Keychain, never written to disk in plain text"))

            HStack {
                Text(tr("模型 ID / Endpoint ID", "Model ID / Endpoint ID"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(vm.isFetchingModels ? tr("获取中…", "Fetching…") : tr("获取列表", "Fetch List")) { vm.fetchModels() }
                    .font(.system(size: 11))
                    .disabled(!vm.canFetchModels)
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
            modelPicker(selection: $profile.modelId)
            hint(tr("示例：gpt-4o-mini  /  qwen-turbo  /  doubao-1-5-pro-32k",
                    "e.g. gpt-4o-mini  /  qwen-turbo  /  doubao-1-5-pro-32k"))

            groupBox {
                label(tr("Vision 模型 ID（可选，多模态截图分析用）", "Vision Model ID (optional, for multimodal screenshot analysis)"))
                modelPicker(selection: $profile.visionModelId)
                hint(tr("留空则复用 Model ID。多模态请求自动走此模型，纯文本请求仍走 Model ID",
                        "Leave empty to reuse Model ID. Multimodal requests use this model; text-only requests still use Model ID"))
            }
            .padding(.top, 8)

            groupBox {
                label(tr("压缩模型 ID（可选，长会议上下文压缩用）", "Compression Model ID (optional, for long-meeting context compression)"))
                modelPicker(selection: $profile.compressionModelId)
                hint(tr("留空则复用 Model ID。用于压缩长会议历史，可用速度较快的轻量模型",
                        "Leave empty to reuse Model ID. Used to compress long meeting history; a fast lightweight model works well"))
            }
            .padding(.top, 8)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.isActive ? tr("当前使用中", "Active") : tr("未激活", "Inactive"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(profile.isActive ? Color(hex: 0x22C55E) : .secondary)
                    Text(tr("启动监听时将自动测试此接口", "This connection is tested automatically when listening starts"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("设为当前使用", "Set as Active")) { vm.setActiveProfile() }
                    .font(.system(size: 11))
                    .disabled(profile.isActive)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            .padding(.top, 16)

            Button(tr("测试 LLM 连接", "Test LLM Connection")) { vm.testConnection() }
                .padding(.top, 12)
        }
    }

    private func modelPicker(selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField("", text: selection)
                .textFieldStyle(.roundedBorder)
            if !vm.availableModels.isEmpty {
                Menu("▼") {
                    ForEach(vm.availableModels, id: \.self) { m in
                        Button(m) { selection.wrappedValue = m }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.secondary.opacity(0.8))
            .padding(.top, 3)
    }

    private func groupBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
