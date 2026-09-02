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

@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published public var step = 0
    @Published public var userName = ""
    @Published public var userNicknames = ""
    @Published public var baseUrl = "http://localhost:8000/v1"
    @Published public var apiKey = ""
    @Published public var modelId = ""
    @Published public var isTesting = false
    @Published public var testResult = ""

    public static let totalSteps = 4

    public func saveIdentity() {
        KeychainStorage.save(StoreKeys.userName, value: userName)
        KeychainStorage.save(StoreKeys.userNicknames, value: userNicknames)
    }

    public func saveLlmProfile() {
        guard !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty,
              !modelId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var p = LlmProfile()
        p.name = tr("默认配置", "Default")
        p.baseUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        p.apiKey = apiKey
        p.modelId = modelId.trimmingCharacters(in: .whitespaces)
        p.isActive = true
        LlmProfileStore.save([p])
    }

    public func testLlm() {
        isTesting = true
        testResult = ""
        saveLlmProfile()
        Task { @MainActor in
            do {
                let service = ConfigurableLlmService()
                let reply = try await service.test()
                testResult = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? tr("连接失败：空响应", "Connection failed: empty response")
                    : tr("连接成功", "Connected")
            } catch {
                testResult = tr("连接失败：", "Connection failed: ") + error.localizedDescription
            }
            isTesting = false
        }
    }

    public var testSucceeded: Bool {
        testResult == tr("连接成功", "Connected")
    }
}

public struct OnboardingView: View {
    @StateObject private var vm = OnboardingViewModel()
    public var onFinish: () -> Void

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    public static func needsShow() -> Bool {
        !KeychainStorage.loadBool(StoreKeys.onboardingDone)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<OnboardingViewModel.totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= vm.step ? Color.accentColor : Color(nsColor: .separatorColor))
                        .frame(width: i == vm.step ? 9 : 7, height: i == vm.step ? 9 : 7)
                }
            }
            .animation(.spring(duration: 0.3), value: vm.step)
            .padding(.top, 20)

            Group {
                switch vm.step {
                case 0: welcomeStep
                case 1: identityStep
                case 2: llmStep
                default: doneStep
                }
            }
            .id(vm.step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .animation(.spring(duration: 0.4), value: vm.step)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if vm.step > 0, vm.step < OnboardingViewModel.totalSteps - 1 {
                    Button(tr("上一步", "Back")) { vm.step -= 1 }
                }
                Spacer()
                if vm.step == 2 {
                    Button(tr("跳过，稍后配置", "Skip for now")) { finish() }
                }
                Button(nextTitle) { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 520, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text(tr("欢迎使用 CalledMe", "Welcome to CalledMe"))
                .font(.title.weight(.bold))
            Text(tr(
                "CalledMe 会在会议中实时转写内容，并在有人叫到你名字时立刻提醒你。\n开始前需要授予以下权限：",
                "CalledMe transcribes your meetings live and alerts you the moment someone says your name.\nTo get started, please grant the following permissions:"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
            VStack(alignment: .leading, spacing: 12) {
                permRow("waveform", tr("语音识别 — 设备端实时转写", "Speech Recognition — on-device live transcription"))
                permRow("display", tr("屏幕录制 — 采集系统音频并定时截图", "Screen Recording — captures system audio and periodic screenshots"))
                permRow("mic", tr("麦克风（可选）— 同时采集你的发言", "Microphone (optional) — captures your own voice"))
            }
            .padding(.top, 6)
            Button(tr("立即授权", "Grant Permissions")) {
                PermissionManager.shared.requestInitialPermissions()
            }
            .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Label(tr("先认识你", "Tell Us Who You Are"), systemImage: "person.crop.circle")
                .font(.title2.weight(.bold))
            Text(tr(
                "当会议中有人叫到你的名字时，CalledMe 会弹窗提醒你并附上当时的截图与上下文。多个名字用逗号分隔。",
                "When someone says your name in a meeting, CalledMe pops up an alert with a screenshot and the surrounding context. Separate multiple names with commas."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("姓名", "Your Name")).font(.callout.weight(.medium))
                TextField(tr("例如：张伟", "e.g. Alex Chen"), text: $vm.userName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("昵称 / 英文名（可选）", "Nicknames (optional)")).font(.callout.weight(.medium))
                TextField(tr("例如：小伟, Will", "e.g. Al, Alex C"), text: $vm.userNicknames)
                    .textFieldStyle(.roundedBorder)
            }
            Label(tr("语音识别偶尔会把名字听成同音字，CalledMe 会自动学习这些变体。",
                     "Speech recognition sometimes mishears names as homophones — CalledMe learns these variants automatically."),
                  systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 48)
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Label(tr("配置 AI 模型", "Configure Your AI Model"), systemImage: "brain")
                .font(.title2.weight(.bold))
            Text(tr(
                "CalledMe 使用 OpenAI 兼容接口生成摘要和检测议题。推荐在本机通过 oMLX 运行 Qwen3.6 系列多模态大模型——同时理解转写文本与会议截图，零费用、全离线。也可使用任意云端服务。",
                "CalledMe uses any OpenAI-compatible API for summaries and topic detection. We recommend running a Qwen3.6-series multimodal model locally via oMLX — it understands both transcripts and meeting screenshots, free and fully offline. Cloud services work too."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
            field(tr("接口地址", "Base URL"), tr("oMLX 默认: http://localhost:8000/v1", "oMLX default: http://localhost:8000/v1"), $vm.baseUrl)
            field(tr("API Key（本地可留空）", "API Key (optional for local)"), "sk-...", $vm.apiKey)
            field(tr("模型", "Model"), tr("例如：Qwen3.6 多模态 / gpt-4o-mini", "e.g. Qwen3.6 multimodal / gpt-4o-mini"), $vm.modelId)
            HStack(spacing: 10) {
                Button(tr("测试连接", "Test Connection")) { vm.testLlm() }
                    .disabled(vm.isTesting)
                if vm.isTesting { ProgressView().controlSize(.small) }
                if !vm.testResult.isEmpty {
                    Label(vm.testResult, systemImage: vm.testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(vm.testSucceeded ? Color.green : Color.red)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 48)
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(tr("一切就绪！", "You're All Set!"))
                .font(.title.weight(.bold))
            VStack(alignment: .leading, spacing: 12) {
                guideRow("1", tr("开会前，点击浮动窗的「开始监听」", "Before a meeting, press \"Start Listening\" in the floating window"))
                guideRow("2", tr("转写实时滚动，议题自动更新", "Transcripts stream in live and topics update automatically"))
                guideRow("3", tr("有人叫你时，弹窗 + 截图 + 上下文立刻出现", "When your name comes up, you get an alert with a screenshot and context"))
                guideRow("4", tr("会后点「摘要」，一键生成会议纪要", "After the meeting, press \"Summary\" for instant minutes"))
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 56)
    }

    private var nextTitle: String {
        switch vm.step {
        case 0: return tr("下一步", "Next")
        case 1: return tr("下一步", "Next")
        case 2: return tr("完成配置", "Save & Continue")
        default: return tr("开始使用", "Start Using CalledMe")
        }
    }

    private func next() {
        switch vm.step {
        case 1: vm.saveIdentity(); vm.step += 1
        case 2: vm.saveLlmProfile(); finish()
        case OnboardingViewModel.totalSteps - 1: finish()
        default: vm.step += 1
        }
    }

    private func finish() {
        KeychainStorage.saveBool(StoreKeys.onboardingDone, true)
        onFinish()
    }

    private func permRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func guideRow(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium))
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }
}
