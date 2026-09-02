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

import AVFoundation
import CoreGraphics
import Foundation

@MainActor
@Observable
public final class FloatingWindowViewModel {
    private let audio: AudioCaptureService
    private let asr: AsrService
    private let llm: LlmService
    private let screen: ScreenCaptureService
    private let nameDetection: NameDetectionService
    private let vision: VisionService
    private let popups: PopupManaging

    public var isMonitoring = false
    public var isSelfTestRunning = false
    public var isManualAlertRunning = false
    public var currentTopic = tr("（未开始）", "(Not Started)")
    public var latestTranscript = ""
    public var elapsedTime = "00:00:00"
    public var statusText = tr("就绪", "Ready")
    public var hasSessionData = false
    public var captureWindowTitle = "" {
        didSet {
            if pendingStartAfterWindowSelect, !captureWindowTitle.trimmingCharacters(in: .whitespaces).isEmpty,
               WindowListHelper.windowID(forTitle: captureWindowTitle) != nil {
                pendingStartAfterWindowSelect = false
                Task { await self.startListening() }
            }
        }
    }
    public var inlineSummaryText = ""
    public var isInlineSummaryLoading = false
    public var selfTestResult = ""
    public var selfTestPassed = false
    public var availableWindows: [String] = []
    public var diagnosticSteps: [DiagnosticItem] = []
    public var isDiagnosticVisible = false
    public var diagnosticHint = ""
    public var isMultimodalEnabled = false
    public var audioLevelSegments: Int = 0
    public var topicFlashId = UUID()

    public var hasSelfTestResult: Bool { !selfTestResult.isEmpty }
    public var hasDiagnosticHint: Bool { !diagnosticHint.isEmpty }
    public var hasInlineSummary: Bool { !inlineSummaryText.isEmpty }

    private var stepDevice: DiagnosticItem?
    private var stepAsr: DiagnosticItem?
    private var stepAudio: DiagnosticItem?
    private var stepTranscript: DiagnosticItem?
    private var stepPlay: DiagnosticItem?
    private var stepScreenshot: DiagnosticItem?
    private var stepLlm: DiagnosticItem?
    private var stepNameAlert: DiagnosticItem?
    private var stepVisionModel: DiagnosticItem?
    private var stepVisionAnalysis: DiagnosticItem?

    private var audioCheckTask: Task<Void, Never>?
    private var transcriptCheckTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var inlineSummaryTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?

    private var audioSignalReceived = false
    private var transcriptReceived = false

    private var lastTranscriptAt = Date.distantPast
    private var lastSpeechBoundaryAt = Date.distantPast
    private var lastAudioRms: Float = 0

    private var selfTestContinuation: CheckedContinuation<String, Never>?

    private var startTime = Date()
    private var transcriptHistory: [String] = []
    private var timestampedHistory: [(time: Date, text: String)] = []
    // Per-track in-progress partial results, keyed by speaker label ("" = unlabeled single track)
    private struct TrackPartial { var text = ""; var uid = -1 }
    private var trackPartials: [String: TrackPartial] = [:]
    // Recent remote-track utterances, used to drop mic-track echo of the
    // remote party's voice when listening on speakers.
    private var recentRemoteUtterances: [(time: Date, text: String)] = []
    private var lastNameAlertFiredAt = Date.distantPast

    private var currentSession: MeetingSession?
    private var currentTopicRef: Topic?
    private var sessionTranscripts: [Transcript] = []
    private var sessionScreenshotMap: [String: Screenshot] = [:]

    private var transcriptsSinceTopicCheck = 0
    private var topicDetecting = false
    private var isStarting = false
    private var asrReconnecting = false

    private var lastSpeakerLabel: String?
    private var speakerNameMap: [String: String] = [:]
    private var pendingSpeakerLabels: Set<String> = []
    private var pendingVisionCount = 0
    private var currentDecisions: [String] = []
    private var currentActionItems: [(assignedTo: String, task: String, deadline: String?)] = []
    private var transcriptsSinceConclusionCheck = 0
    private var conclusionDetecting = false

    private var contextManager: ContextWindowManager?
    private var pendingStartAfterWindowSelect = false
    private nonisolated(unsafe) var permissionObserver: NSObjectProtocol?

    private static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    public init(audio: AudioCaptureService = AppServices.shared.audio,
                asr: AsrService = AppServices.shared.asr,
                llm: LlmService = AppServices.shared.llm,
                screen: ScreenCaptureService = AppServices.shared.screen,
                nameDetection: NameDetectionService = AppServices.shared.nameDetection,
                vision: VisionService = AppServices.shared.vision,
                popups: PopupManaging = PopupManager.shared) {
        self.audio = audio
        self.asr = asr
        self.llm = llm
        self.screen = screen
        self.nameDetection = nameDetection
        self.vision = vision
        self.popups = popups

        captureWindowTitle = KeychainStorage.load(StoreKeys.captureWindowTitle) ?? ""
        isMultimodalEnabled = KeychainStorage.loadBool(StoreKeys.multimodalEnabled)
        initDiagnosticSteps()

        asr.onTranscript = { [weak self] event in
            Task { @MainActor in self?.onTranscript(event) }
        }
        asr.onError = { [weak self] message in
            Task { @MainActor in self?.onAsrError(message) }
        }
        audio.onAudioLevel = { [weak self] rms in
            Task { @MainActor in self?.onAudioLevel(rms) }
        }
        screen.onScreenshot = { [weak self] event in
            Task { @MainActor in self?.onScreenshot(event) }
        }

        PopupManager.shared.onQuickSummaryRefresh = { [weak self] in
            Task { @MainActor in await self?.showQuickSummary() }
        }
        PopupManager.shared.onNameAlertAcknowledged = { _ in }

        permissionObserver = NotificationCenter.default.addObserver(
            forName: .mmScreenCapturePermissionGranted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshWindows()
                if self.pendingStartAfterWindowSelect, !self.isMonitoring {
                    await self.startListening()
                }
            }
        }
    }

    deinit {
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
        }
    }

    public func getRecentTranscripts(_ maxEntries: Int = 100) -> [String] {
        Array(transcriptHistory.suffix(maxEntries))
    }

    public func resetTranscriptDisplay() {
        transcriptHistory.removeAll()
        trackPartials.removeAll()
        latestTranscript = ""
    }

    // MARK: - Commands

    public func toggleMultimodalMode() {
        isMultimodalEnabled = !isMultimodalEnabled
        KeychainStorage.saveBool(StoreKeys.multimodalEnabled, isMultimodalEnabled)
        if !isMultimodalEnabled { contextManager?.clearScreenshots() }
    }

    public func startListening() async {
        if isMonitoring || isStarting { return }
        isStarting = true
        defer { isStarting = false }

        currentDecisions.removeAll()
        currentActionItems.removeAll()
        lastSpeakerLabel = nil
        speakerNameMap.removeAll()
        pendingSpeakerLabels.removeAll()
        sessionTranscripts.removeAll()
        sessionScreenshotMap.removeAll()

        if LlmProfileStore.active() == nil {
            statusText = tr("请先在设置 → 大模型 中配置并激活一个接口",
                            "Configure and activate an LLM profile in Settings → LLM first")
            WindowRouter.openSettings()
            return
        }

        if !PermissionsHelper.screenCaptureGranted() {
            statusText = tr("需要屏幕录制权限", "Screen Recording Permission Required")
            isDiagnosticVisible = true
            diagnosticHint = tr("开始监听需要屏幕录制权限（用于采集系统音频与截图）。\n请在系统设置 → 隐私与安全性 → 屏幕录制 中允许 CalledMe，授权后应用会自动重启生效。",
                                "Starting listening requires screen recording permission (used for system audio capture and screenshots).\nAllow CalledMe in System Settings → Privacy & Security → Screen Recording. The app restarts automatically after authorization.")
            PermissionsHelper.requestScreenCapture()
            PermissionManager.shared.startScreenPermissionWatcher()
            return
        }

        let windowValid = !captureWindowTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && WindowListHelper.windowID(forTitle: captureWindowTitle) != nil
        if !windowValid {
            statusText = tr("请选择当前运行的会议窗口", "Select the running meeting window")
            refreshWindows()
            if availableWindows.isEmpty {
                diagnosticHint = tr("未检测到可捕获的窗口。请确认会议窗口已打开且未最小化，然后刷新列表后选择。",
                                    "No capturable windows detected. Make sure the meeting window is open and not minimized, then refresh the list and select it.")
                isDiagnosticVisible = true
            }
            pendingStartAfterWindowSelect = true
            return
        }

        if PermissionsHelper.speechAuthorizationStatus() != .authorized {
            let status = await PermissionsHelper.requestSpeechAuthorization()
            if status != .authorized {
                statusText = tr("需要语音识别权限", "Speech Recognition Permission Required")
                isDiagnosticVisible = true
                diagnosticHint = tr("请在系统设置 → 隐私与安全性 → 语音识别 中允许 CalledMe 后重试。",
                                    "Allow CalledMe in System Settings → Privacy & Security → Speech Recognition, then try again.")
                return
            }
        }


        resetDiagnostics()
        isDiagnosticVisible = true

        stepDevice?.setRunning(tr("检测音频设备...", "Checking audio device..."))
        statusText = tr("检测音频设备...", "Checking audio device...")
        do {
            try await audio.start()
            let devName = audio.currentDeviceName ?? tr("默认音频设备", "Default Audio Device")
            stepDevice?.setOk(devName)
        } catch {
            stepDevice?.setError(error.localizedDescription)
            diagnosticHint = tr("未找到音频设备，请检查声音设备设置", "No audio device found. Check your sound device settings")
            statusText = tr("音频设备错误", "Audio Device Error")
            return
        }

        stepAsr?.setRunning(tr("连接 ASR 服务...", "Connecting ASR..."))
        statusText = tr("连接 ASR...", "Connecting ASR...")
        do {
            try await asr.connect()
            stepAsr?.setOk(tr("已连接", "Connected"))
        } catch {
            stepAsr?.setError(error.localizedDescription)
            diagnosticHint = tr("请检查：① 语音识别权限是否已授权 ② 网络是否可用",
                                "Check: ① Speech recognition permission is granted ② Network is available")
            statusText = tr("ASR 连接失败", "ASR Connection Failed")
            await audio.stop()
            return
        }

        audio.setAsr(asr)

        audioSignalReceived = false
        transcriptReceived = false
        stepAudio?.setRunning(tr("等待声音...", "Waiting for audio..."))
        stepTranscript?.setRunning(tr("等待转录...", "Waiting for transcript..."))

        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.audioSignalReceived else { return }
            self.stepAudio?.setWarning(tr("静音", "Silent"))
            self.diagnosticHint = tr("未检测到声音，请检查：\n① 系统音量未静音  ② 默认播放设备正确  ③ 正在播放音频",
                                     "No audio detected. Check:\n① System volume is not muted  ② Default output device is correct  ③ Audio is playing")
        }

        transcriptCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.transcriptReceived else { return }
            self.stepTranscript?.setWarning(tr("30s 内无转录", "No transcript in 30s"))
            if self.diagnosticHint.isEmpty {
                self.diagnosticHint = tr("已收到音频但无文字，请检查：\n① 音频是否为清晰的语音  ② 语音识别权限是否已授权",
                                         "Audio received but no text. Check:\n① The audio is clear speech  ② Speech recognition permission is granted")
            }
            self.isDiagnosticVisible = true
        }

        lastTranscriptAt = Date()
        lastSpeechBoundaryAt = Date()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                await self.watchdogTick()
            }
        }

        inlineSummaryText = ""
        isInlineSummaryLoading = false
        inlineSummaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, self.isMonitoring else { continue }
                await self.refreshInlineSummary()
            }
        }

        startTime = Date()
        transcriptsSinceTopicCheck = 0
        transcriptsSinceConclusionCheck = 0
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let elapsed = Int(Date().timeIntervalSince(self.startTime))
                self.elapsedTime = String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60)
            }
        }

        createSession(startTime: startTime)

        let cm = ContextWindowManager()
        let sessionTitle = tr("会议 \(Self.monthDayHHmm(startTime))", "Meeting \(Self.monthDayHHmm(startTime))")
        cm.setMeetingTitle(sessionTitle)
        contextManager = cm

        isMonitoring = true
        hasSessionData = true
        statusText = tr("监听中", "Listening")
        currentTopic = ""

        KeychainStorage.save(StoreKeys.captureWindowTitle, value: captureWindowTitle)
        var captureWindowID: CGWindowID? = nil
        if let id = WindowListHelper.windowID(forTitle: captureWindowTitle) {
            captureWindowID = id
        } else {
        }
        do {
            try await screen.start(windowID: captureWindowID)
        } catch {
        }
    }

    public func stopListening() async {
        guard isMonitoring else { return }

        statusText = tr("停止中...", "Stopping...")
        audioLevelSegments = 0

        elapsedTask?.cancel(); elapsedTask = nil
        audioCheckTask?.cancel(); audioCheckTask = nil
        transcriptCheckTask?.cancel(); transcriptCheckTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        inlineSummaryTask?.cancel(); inlineSummaryTask = nil
        inlineSummaryText = ""

        await screen.stop()
        audio.setAsr(nil)
        await audio.stop()
        await asr.disconnect()

        if let topic = currentTopicRef {
            for (key, partial) in trackPartials {
                let text = partial.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let label = key.isEmpty ? nil : key
                if let label, label == Self.resolvedSelfLabel, isEchoOfRemote(text) { continue }
                appendHistory(text, speaker: label)
                saveTranscript(topic: topic, text: text, speakerLabel: label)
            }
        }
        trackPartials.removeAll()
        recentRemoteUtterances.removeAll()

        isMonitoring = false
        statusText = tr("已停止", "Stopped")
        currentTopic = tr("（已结束）", "(Ended)")
        latestTranscript = ""
        inlineSummaryText = ""
        transcriptsSinceConclusionCheck = 0
        topicDetecting = false
        conclusionDetecting = false

        let session = currentSession
        let finalTopic = currentTopicRef
        currentSession = nil
        currentTopicRef = nil
        lastSpeakerLabel = nil
        speakerNameMap.removeAll()
        pendingSpeakerLabels.removeAll()
        contextManager?.clear()
        contextManager = nil

        if let session {
            await endSession(session, finalTopic: finalTopic)
        }
    }

    public func toggleDiagnostics() {
        isDiagnosticVisible.toggle()
    }

    public func runSelfTest() async {
        guard !isMonitoring, !isSelfTestRunning else { return }
        isSelfTestRunning = true
        selfTestResult = ""
        selfTestPassed = false
        statusText = tr("功能自检中...", "Running Self Test...")

        resetDiagnostics()
        let play = DiagnosticItem(name: tr("测试播报", "Test Playback"))
        let shot = DiagnosticItem(name: tr("截图", "Screenshot"))
        let llmStep = DiagnosticItem(name: tr("LLM 摘要", "LLM Summary"))
        let nameAlert = DiagnosticItem(name: tr("被叫提醒", "Name Alert"))
        let visionModel = DiagnosticItem(name: tr("Vision 模型", "Vision Model"))
        let visionAnalysis = DiagnosticItem(name: tr("Vision 分析", "Vision Analysis"))
        stepPlay = play
        stepScreenshot = shot
        stepLlm = llmStep
        stepNameAlert = nameAlert
        stepVisionModel = visionModel
        stepVisionAnalysis = visionAnalysis
        diagnosticSteps.append(contentsOf: [play, shot, llmStep, nameAlert, visionModel, visionAnalysis])
        isDiagnosticVisible = true

        var audioStarted = false
        var asrConnected = false
        var abortAsr = false

        do {
            stepDevice?.setRunning(tr("检测音频设备...", "Checking audio device..."))
            do {
                try await audio.start()
                audioStarted = true
                stepDevice?.setOk(audio.currentDeviceName ?? tr("默认音频设备", "Default Audio Device"))
            } catch {
                stepDevice?.setError(error.localizedDescription)
                selfTestResult = tr("音频设备错误：\(error.localizedDescription)", "Audio device error: \(error.localizedDescription)")
                diagnosticHint = tr("未找到音频设备，请检查系统声音设置", "No audio device found. Check system sound settings")
                abortAsr = true
            }

            if !abortAsr {
                stepAsr?.setRunning(tr("连接 ASR 服务...", "Connecting ASR..."))
                do {
                    try await asr.connect()
                    asrConnected = true
                    stepAsr?.setOk(tr("已连接", "Connected"))
                } catch {
                    stepAsr?.setError(error.localizedDescription)
                    selfTestResult = tr("ASR 连接失败：\(error.localizedDescription)", "ASR connection failed: \(error.localizedDescription)")
                    diagnosticHint = tr("请检查：① 语音识别权限是否已授权 ② 网络是否可用",
                                        "Check: ① Speech recognition permission is granted ② Network is available")
                    abortAsr = true
                }
            }

            if !abortAsr {
                audio.setAsr(asr)
                stepAudio?.setRunning(tr("等待声音...", "Waiting for audio..."))
                stepTranscript?.setRunning(tr("等待转录...", "Waiting for transcript..."))

                try? await Task.sleep(for: .milliseconds(800))

                stepPlay?.setRunning(tr("正在播放测试语音...", "Playing test speech..."))
                let isEn = AppLanguage.current.isEnglish
                SelfTestAudio.speak()
                stepPlay?.setOk(tr("已播放", "Played") + (isEn ? "" : tr("（英文）", " (EN)")))
                if AVSpeechSynthesisVoice(language: "zh-CN") == nil {
                }

                try? await Task.sleep(for: .milliseconds(2500))
                try? await asr.finalizeSegment()

                stepTranscript?.setRunning(tr("等待 ASR 返回...", "Waiting for ASR response..."))
                let text = await waitForSelfTestTranscript(timeout: 8)

                if !text.isEmpty {
                    stepTranscript?.setOk(tr("转录正常", "Transcription OK"))
                    selfTestPassed = true
                    selfTestResult = tr("ASR 自检通过 — 转录：\(text)", "ASR self test passed — transcript: \(text)")
                    diagnosticHint = ""
                } else {
                    let audioOk = stepAudio?.state == .ok
                    if !audioOk {
                        stepAudio?.setError(tr("未捕获到声音", "No audio captured"))
                        stepTranscript?.setWarning(tr("未到达 ASR", "Did not reach ASR"))
                        selfTestResult = tr("系统音频未能捕获播放声音", "System audio failed to capture the played sound")
                        diagnosticHint = tr("软件已播放测试语音，但系统音频采集无信号。\n请检查：\n① 系统音量未静音\n② 默认播放设备设置正确\n③ 屏幕录制权限已授予（系统音频采集依赖该权限）",
                                            "The app played the test speech, but system audio capture got no signal.\nCheck:\n① System volume is not muted\n② Default output device is correct\n③ Screen recording permission is granted (system audio capture depends on it)")
                    } else {
                        stepTranscript?.setError(tr("无 ASR 响应", "No ASR response"))
                        selfTestResult = tr("音频已捕获，但 ASR 无返回", "Audio captured, but ASR returned nothing")
                        diagnosticHint = tr("请检查：\n① 语音识别权限是否已授权\n② 语音模型是否已下载\n③ 网络是否可用",
                                            "Check:\n① Speech recognition permission is granted\n② Speech model is downloaded\n③ Network is available")
                    }
                }
            }

            if abortAsr {
                if stepAsr?.state == .pending { stepAsr?.setWarning(tr("已跳过", "Skipped")) }
                if stepAudio?.state == .pending { stepAudio?.setWarning(tr("已跳过", "Skipped")) }
                if stepTranscript?.state == .pending { stepTranscript?.setWarning(tr("已跳过", "Skipped")) }
                if stepPlay?.state == .pending { stepPlay?.setWarning(tr("已跳过", "Skipped")) }
            }

            var selfTestScreenshotPath: String? = nil
            stepScreenshot?.setRunning(tr("截图中...", "Capturing..."))
            do {
                selfTestScreenshotPath = try await screen.takeScreenshot()
                stepScreenshot?.setOk(tr("已保存", "Saved"))
            } catch {
                stepScreenshot?.setError(error.localizedDescription)
            }

            stepLlm?.setRunning(tr("调用 LLM...", "Calling LLM..."))
            do {
                let reply = try await withTimeout(15) { [llm] in
                    try await llm.analyze(tr("请用一句话回复\"LLM摘要连接正常\"", "Reply in one sentence: \"LLM summary connection OK\""))
                }
                let preview = reply.count > 24 ? String(reply.prefix(24)) + "…" : reply
                stepLlm?.setOk(preview)
            } catch is TimeoutError {
                stepLlm?.setError(tr("超时（15s）", "Timed out (15s)"))
            } catch {
                stepLlm?.setError(error.localizedDescription)
            }

            stepNameAlert?.setRunning(tr("触发提醒...", "Triggering alert..."))
            var userName = KeychainStorage.load(StoreKeys.userName)?.trimmingCharacters(in: .whitespaces) ?? ""
            if userName.isEmpty { userName = tr("用户", "User") }
            popups.showNameAlert(NameAlertData(
                detectedAt: Date(),
                quote: tr("[自检] 请问\(userName)，你觉得这个方案怎么样？", "[Self Test] \(userName), what do you think of this proposal?"),
                questions: [tr("你觉得这个方案怎么样？", "What do you think of this proposal?")],
                context: [TranscriptContextLine(time: Self.hhmmss.string(from: Date()), speaker: nil, text: tr("[功能自检] 测试被叫到姓名提醒弹窗", "[Self Test] Testing the name-called alert popup"))],
                screenshotPath: selfTestScreenshotPath))
            stepNameAlert?.setOk(tr("弹窗已触发", "Alert Triggered"))

            if isMultimodalEnabled {
                stepVisionModel?.setRunning(tr("测试 Vision 连接...", "Testing Vision connection..."))
                do {
                    let ok = try await vision.testConnection()
                    if ok {
                        stepVisionModel?.setOk(tr("Vision 模型可用", "Vision model available"))
                    } else {
                        stepVisionModel?.setWarning(tr("Vision 模型无响应", "Vision model not responding"))
                    }
                } catch {
                    stepVisionModel?.setError(error.localizedDescription)
                }

                stepVisionAnalysis?.setRunning(tr("测试截图分析...", "Testing screenshot analysis..."))
                do {
                    if let path = selfTestScreenshotPath, FileManager.default.fileExists(atPath: path) {
                        let result = try await vision.analyzeScreenshot(imagePath: path, currentTopic: "[自检]", surroundingTranscripts: [])
                        let summary = result.aiSummary.trimmingCharacters(in: .whitespaces)
                        let isFallback = summary.hasPrefix("[") && summary.hasSuffix("]")
                        if !summary.isEmpty, !isFallback {
                            stepVisionAnalysis?.setOk(tr("分析正常", "Analysis OK"))
                        } else {
                            let reason = summary.isEmpty
                                ? tr("空响应", "Empty response") : summary.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                            stepVisionAnalysis?.setWarning(tr("分析未返回有效内容 (\(reason))", "Analysis returned no valid content (\(reason))"))
                            diagnosticHint = tr("Vision 分析失败：请确认设置的模型支持多模态（如 gpt-4o、qwen-vl、claude-sonnet等），且已在设置页配置正确的 Vision 模型 ID。",
                                                "Vision analysis failed: make sure the configured model supports multimodal input (e.g. gpt-4o, qwen-vl, claude-sonnet) and the correct Vision model ID is set in Settings.")
                        }
                    } else {
                        stepVisionAnalysis?.setWarning(tr("无测试截图", "No test screenshot"))
                    }
                } catch {
                    stepVisionAnalysis?.setWarning(tr("分析测试异常: \(error.localizedDescription)", "Analysis test error: \(error.localizedDescription)"))
                }
            } else {
                stepVisionModel?.setOk(tr("已跳过 (纯文本模式)", "Skipped (text-only mode)"))
                stepVisionModel?.detail = tr("启用多模态后可测试", "Enable multimodal to test")
                stepVisionAnalysis?.setOk(tr("已跳过 (纯文本模式)", "Skipped (text-only mode)"))
                stepVisionAnalysis?.detail = tr("启用多模态后可测试", "Enable multimodal to test")
            }
        } catch {
            selfTestResult = tr("自检意外错误：\(error.localizedDescription)", "Unexpected self test error: \(error.localizedDescription)")
            diagnosticHint = tr("请查看应用日志获取详情", "See the app logs for details")
        }

        audio.setAsr(nil)

        if audioStarted {
            await audio.stop()
        }
        if asrConnected {
            await asr.disconnect()
        }

        selfTestContinuation = nil
        isSelfTestRunning = false
        statusText = tr("就绪", "Ready")
    }

    public func manualTriggerAlert() async {
        guard isMonitoring, !isManualAlertRunning else { return }
        isManualAlertRunning = true
        defer { isManualAlertRunning = false }

        do {
            let recent = Array(timestampedHistory.suffix(16))
            let contextLines = recent.map { $0.text }
            let contextText = contextLines.joined(separator: "\n")
            let triggeredAt = Date()

            var screenshotPath: String? = nil
            do {
                screenshotPath = try await screen.takeScreenshot()
            } catch {
            }

            var questions: [String]
            do {
                let storedName = KeychainStorage.load(StoreKeys.userName)?.trimmingCharacters(in: .whitespaces) ?? ""
                let userName = storedName.isEmpty ? tr("用户", "User") : storedName
                let userRole = KeychainStorage.load(StoreKeys.userRole)?.trimmingCharacters(in: .whitespaces) ?? ""
                let roleHint = userRole.isEmpty ? "" : tr("\n用户角色：\(userRole)", "\nUser role: \(userRole)")
                let prompt: String
                if AppLanguage.current.isEnglish {
                    prompt = """
                    User name: \(userName)\(roleHint)

                    Here are the most recent meeting transcript lines (one per line):
                    \(contextText)

                    Extract the questions recently asked of this user or items that require their response.
                    Return JSON only, format: {"questions":["question 1","question 2"]}
                    If there are no clear questions, return: {"questions":["(Please confirm what was just mentioned)"]}
                    """
                } else {
                    prompt = """
                    用户姓名：\(userName)\(roleHint)

                    以下是会议最近的转录文本（每行一条）：
                    \(contextText)

                    请从上述文本中提取最近向该用户提出的问题或需要该用户回应的事项。
                    只返回JSON，格式：{"questions":["问题1","问题2"]}
                    若没有明确问题，返回：{"questions":["（请确认刚才被提及的内容）"]}
                    """
                }
                let reply = try await withTimeout(12) { [llm] in try await llm.analyze(prompt) }
                questions = parseQuestions(reply)
                if questions.isEmpty { throw TimeoutError() }
            } catch {
                questions = [tr("（请确认刚才被提及的内容）", "(Please confirm what was just mentioned)")]
            }

            let originalText = recent.last?.text ?? tr("（手动触发）", "(Manual trigger)")
            let context = recent.map {
                TranscriptContextLine(time: Self.hhmmss.string(from: $0.time), speaker: nil, text: $0.text)
            }
            popups.showNameAlert(NameAlertData(
                detectedAt: triggeredAt,
                quote: originalText,
                questions: questions,
                context: context,
                screenshotPath: screenshotPath))
        } catch {
        }
    }

    public func showQuickSummary() async {
        popups.showQuickSummary(QuickSummaryData(isLoading: true))
        isInlineSummaryLoading = true
        inlineSummaryText = ""

        do {
            let transcripts = getRecentTranscripts(100)
            if transcripts.isEmpty {
                popups.updateQuickSummary(QuickSummaryData(isLoading: false, topic: currentTopic, summary: tr("暂无会议内容", "No meeting content yet"), decisions: [], actionItems: []))
                isInlineSummaryLoading = false
                inlineSummaryText = tr("（暂无转写内容）", "(No transcript content)")
                return
            }

            let role = KeychainStorage.load(StoreKeys.userRole)
            let screenshotSummaries = contextManager?.buildContext().screenshotSummaries
            let prompt = Self.buildSummaryPrompt(transcripts: transcripts, detailed: true, userRole: role, screenshotSummaries: screenshotSummaries)
            let response = try await withTimeout(30) { [llm] in try await llm.analyze(prompt) }
            let parsed = Self.parseSummaryJson(response)

            if !parsed.decisions.isEmpty {
                for d in parsed.decisions where !currentDecisions.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) {
                    currentDecisions.append(d)
                }
                if let topic = currentTopicRef {
                    saveDecisions(topic: topic, parsed.decisions)
                }
            }
            if !parsed.actions.isEmpty {
                for a in parsed.actions where !currentActionItems.contains(where: { $0.task.caseInsensitiveCompare(a.task) == .orderedSame }) {
                    currentActionItems.append(a)
                }
                if let topic = currentTopicRef {
                    saveActionItems(topic: topic, parsed.actions)
                }
            }

            let allActionStrings = currentActionItems.map { item in
                item.deadline.map { "\(item.assignedTo)：\(item.task)（\($0)）" } ?? "\(item.assignedTo)：\(item.task)"
            }

            popups.updateQuickSummary(QuickSummaryData(
                isLoading: false,
                topic: currentTopic,
                summary: parsed.summary,
                decisions: currentDecisions,
                actionItems: allActionStrings))
            isInlineSummaryLoading = false
            inlineSummaryText = parsed.summary
        } catch {
            let errMsg = tr("摘要生成失败：\(error.localizedDescription)", "Failed to generate summary: \(error.localizedDescription)")
            popups.updateQuickSummary(QuickSummaryData(isLoading: false, topic: currentTopic, summary: errMsg, decisions: [], actionItems: []))
            isInlineSummaryLoading = false
            inlineSummaryText = errMsg
        }
    }

    public func openScreenshotAlbum() {
        popups.showScreenshotAlbum()
    }

    public func refreshWindows() {
        let titles = WindowListHelper.listWindows()
            .map { $0.title.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 && $0 != "CalledMe" }
        availableWindows = Array(Set(titles)).sorted()
    }

    // MARK: - Inline summary

    private func refreshInlineSummary() async {
        let transcripts = getRecentTranscripts(50)
        if transcripts.count < 5 { return }

        isInlineSummaryLoading = true
        do {
            let role = KeychainStorage.load(StoreKeys.userRole)
            let screenshotSummaries = contextManager?.buildContext().screenshotSummaries
            let prompt = Self.buildSummaryPrompt(transcripts: transcripts, detailed: false, userRole: role, screenshotSummaries: screenshotSummaries)
            let response = try await withTimeout(30) { [llm] in try await llm.analyze(prompt) }
            let parsed = Self.parseSummaryJson(response)
            inlineSummaryText = parsed.summary
            isInlineSummaryLoading = false
        } catch {
            isInlineSummaryLoading = false
            inlineSummaryText = tr("[摘要生成失败：\(error.localizedDescription)]", "[Failed to generate summary: \(error.localizedDescription)]")
        }
    }

    static func buildSummaryPrompt(transcripts: [String], detailed: Bool, userRole: String?,
                                   screenshotSummaries: [ScreenshotSummary]?) -> String {
        let joined = transcripts.joined(separator: "\n")
        let roleHint = (userRole?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? ""
            : tr("\n（当前用户角色：\(userRole ?? "")，请在摘要和行动项中特别关注与该角色相关的内容）",
                 "\n(Current user role: \(userRole ?? "") — pay special attention to content related to this role in the summary and action items)")
        let screenshotSection = buildScreenshotSection(screenshotSummaries)

        if detailed {
            if AppLanguage.current.isEnglish {
                return """
                Analyze the following meeting transcript and return JSON in this format:
                {"summary":"key points (2-5 sentences)","decisions":["decision 1","decision 2"],"actions":[{"assignedTo":"owner","task":"specific task","deadline":"deadline or null"}]}

                Put only clear decisions in "decisions"; put only action items with a clear owner in "actions".
                Return empty arrays if none. Return JSON only, no Markdown. \(roleHint)

                Transcript:
                \(joined)
                \(screenshotSection)
                """
            }
            return """
            请分析以下会议转录内容，以JSON格式返回，格式：
            {"summary":"要点摘要（2-5句话）","decisions":["决策1","决策2"],"actions":[{"assignedTo":"负责人","task":"具体任务","deadline":"截止时间或null"}]}

            decisions 只放明确的决策结论；actions 只放有明确负责人的行动项。
            若无则返回空数组。只返回JSON，不要Markdown标记。\(roleHint)

            转录内容：
            \(joined)
            \(screenshotSection)
            """
        } else {
            if AppLanguage.current.isEnglish {
                return """
                Summarize the key points of the following meeting discussion in 2-3 sentences, and return JSON:
                {"summary":"brief summary","decisions":[],"actions":[]}

                Return JSON only, no Markdown. \(roleHint)

                Transcript:
                \(joined)
                \(screenshotSection)
                """
            }
            return """
            请用2-3句话总结以下会议讨论要点，以JSON格式返回：
            {"summary":"简短摘要","decisions":[],"actions":[]}

            只返回JSON，不要Markdown标记。\(roleHint)

            转录内容：
            \(joined)
            \(screenshotSection)
            """
        }
    }

    private static func buildScreenshotSection(_ screenshots: [ScreenshotSummary]?) -> String {
        guard let screenshots, !screenshots.isEmpty else { return "" }
        var sb = tr("\n【截图内容分析】（会议期间屏幕展示的内容）\n",
                    "\n[Screenshot Analysis] (content shown on screen during the meeting)\n")
        for s in screenshots {
            sb += "[\(s.timeLabel)] \(s.aiSummary)\n"
        }
        return sb
    }

    static func parseSummaryJson(_ json: String) -> (summary: String, decisions: [String], actions: [(assignedTo: String, task: String, deadline: String?)]) {
        var text = json
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), end > start {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (json, [], [])
        }
        let summary = root["summary"] as? String ?? ""
        let decisions = (root["decisions"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
        var actions: [(String, String, String?)] = []
        if let rawActions = root["actions"] as? [[String: Any]] {
            for item in rawActions {
                let assignedTo = item["assignedTo"] as? String ?? ""
                let task = item["task"] as? String ?? ""
                let deadline = item["deadline"] as? String
                if !task.trimmingCharacters(in: .whitespaces).isEmpty {
                    actions.append((assignedTo, task, deadline))
                }
            }
        }
        return (summary, decisions, actions)
    }

    private func parseQuestions(_ reply: String) -> [String] {
        var text = reply
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), end > start {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["questions"] as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    // MARK: - Diagnostics

    private func initDiagnosticSteps() {
        let device = DiagnosticItem(name: tr("音频设备", "Audio Device"))
        let asrStep = DiagnosticItem(name: tr("ASR 连接", "ASR Connection"))
        let audioStep = DiagnosticItem(name: tr("音频信号", "Audio Signal"))
        let transcript = DiagnosticItem(name: tr("转录识别", "Transcription"))
        stepDevice = device
        stepAsr = asrStep
        stepAudio = audioStep
        stepTranscript = transcript
        diagnosticSteps = [device, asrStep, audioStep, transcript]
    }

    private func resetDiagnostics() {
        diagnosticHint = ""
        stepDevice?.setPending()
        stepAsr?.setPending()
        stepAudio?.setPending()
        stepTranscript?.setPending()

        for s in [stepPlay, stepScreenshot, stepLlm, stepNameAlert, stepVisionModel, stepVisionAnalysis] {
            if let s, let idx = diagnosticSteps.firstIndex(where: { $0 === s }) {
                diagnosticSteps.remove(at: idx)
            }
        }
        stepPlay = nil
        stepScreenshot = nil
        stepLlm = nil
        stepNameAlert = nil
        stepVisionModel = nil
        stepVisionAnalysis = nil
    }

    private func onAudioLevel(_ rms: Float) {
        lastAudioRms = rms

        let segments = isMonitoring ? min(8, max(0, Int((Double(rms) / 0.12).squareRoot() * 8 + 0.5))) : 0
        if segments != audioLevelSegments { audioLevelSegments = segments }

        if rms < 0.005 {
            lastSpeechBoundaryAt = Date()
        }

        if (stepAudio?.state == .running || stepAudio?.state == .warning), rms > 0.005 {
            audioSignalReceived = true
            audioCheckTask?.cancel()
            stepAudio?.setOk(String(format: tr("有声音 (%.3f)", "Audio (%.3f)"), rms))
            if diagnosticHint.contains(tr("未检测到声音", "No audio detected")) {
                diagnosticHint = ""
            }
            tryAutoHideDiagnostics()
        } else if stepAudio?.state == .ok {
            stepAudio?.detail = String(format: tr("有声音 (%.3f)", "Audio (%.3f)"), rms)
        }
    }

    private func tryAutoHideDiagnostics() {
        if stepDevice?.state == .ok, stepAsr?.state == .ok, stepAudio?.state == .ok, stepTranscript?.state == .ok {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                if self.stepDevice?.state == .ok, self.stepAsr?.state == .ok,
                   self.stepAudio?.state == .ok, self.stepTranscript?.state == .ok {
                    self.isDiagnosticVisible = false
                }
            }
        }
    }

    private func watchdogTick() async {
        guard isMonitoring else { return }
        let timeSinceBoundary = Date().timeIntervalSince(lastSpeechBoundaryAt)

        if timeSinceBoundary >= 10, lastAudioRms > 0.003 {
            lastSpeechBoundaryAt = Date()
            trackPartials.removeAll()
            return
        }

        if Date().timeIntervalSince(lastTranscriptAt) >= 30 {
            lastTranscriptAt = Date()
            lastSpeechBoundaryAt = Date()
            await rebuildAsrSession()
        }
    }

    private func rebuildAsrSession() async {
        await asr.disconnect()
        do {
            try await asr.connect()
        } catch {
        }
    }

    // MARK: - ASR handlers

    private func onAsrError(_ message: String) {

        let isAuthError = message.contains("4001") || message.contains("4003") || message.contains("401")
            || message.contains("权限") || message.contains("permission")

        stepAsr?.setError(message)
        stepTranscript?.setError(tr("ASR 服务端错误", "ASR Server Error"))
        diagnosticHint = isAuthError
            ? tr("鉴权失败 — 请检查语音识别权限与配置", "Authentication failed — check speech recognition permission and configuration")
            : tr("服务器返回错误，尝试重连中…", "Server returned an error, reconnecting…")
        isDiagnosticVisible = true
        statusText = tr("ASR 错误", "ASR Error")

        if !isAuthError, isMonitoring, !asrReconnecting {
            asrReconnecting = true
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1))
                await self.rebuildAsrSession()
                self.stepAsr?.setOk(tr("已重连", "Reconnected"))
                self.diagnosticHint = ""
                self.statusText = tr("监听中", "Listening")
                self.asrReconnecting = false
            }
        }
    }

    private func onTranscript(_ e: TranscriptEvent) {
        if isSelfTestRunning, let continuation = selfTestContinuation,
           !e.text.trimmingCharacters(in: .whitespaces).isEmpty {
            selfTestContinuation = nil
            continuation.resume(returning: e.text)
        }

        let trackKey = e.speakerLabel ?? ""
        var partial = trackPartials[trackKey] ?? TrackPartial()
        var committedText: String? = nil
        var committedLabel: String? = nil

        if e.isFinal {
            if !e.text.trimmingCharacters(in: .whitespaces).isEmpty {
                committedText = e.text
                committedLabel = e.speakerLabel
            }
            partial.text = ""
            partial.uid = -1
        } else {
            let uidChanged = e.utteranceId >= 0 && partial.uid >= 0 && e.utteranceId != partial.uid
            let lengthReset = partial.text.count > 10 && e.text.count < Int(Double(partial.text.count) * 0.5)

            if (uidChanged || lengthReset), !partial.text.trimmingCharacters(in: .whitespaces).isEmpty {
                committedText = partial.text
                committedLabel = e.speakerLabel
            }
            partial.text = e.text
            partial.uid = e.utteranceId
        }
        trackPartials[trackKey] = partial

        if let committed = committedText {
            if let label = committedLabel, label == Self.resolvedSelfLabel {
                // The mic re-capturing the remote party's voice from speakers
                // would show the same sentence as "mine" — drop the echo.
                if isEchoOfRemote(committed) {
                    committedText = nil
                    committedLabel = nil
                }
            } else {
                recordRemoteUtterance(committed)
            }
        }
        if let committed = committedText {
            appendHistory(committed, speaker: committedLabel)
        }

        var lines = Array(transcriptHistory.suffix(25))
        for key in trackPartials.keys.sorted() {
            guard let p = trackPartials[key],
                  !p.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append(key.isEmpty ? p.text : "\(key)：\(p.text)")
        }
        latestTranscript = lines.joined(separator: "\n")

        lastTranscriptAt = Date()
        lastSpeechBoundaryAt = Date()

        if !transcriptReceived {
            transcriptReceived = true
            transcriptCheckTask?.cancel()
            stepTranscript?.setOk(tr("转录正常", "Transcription OK"))
            diagnosticHint = ""
            tryAutoHideDiagnostics()
        }

        if let committed = committedText, let topic = currentTopicRef {
            let speakerLabel = committedLabel

            if let speakerLabel, speakerLabel != lastSpeakerLabel {
                lastSpeakerLabel = speakerLabel
                let isSelf = speakerLabel == Self.resolvedSelfLabel
                if !isSelf, screen.isCapturing, speakerNameMap[speakerLabel] == nil, pendingSpeakerLabels.insert(speakerLabel).inserted {
                    Task { [weak self] in
                        guard let self else { return }
                        do { _ = try await self.screen.takeScreenshot() } catch {
                        }
                    }
                }
            }

            saveTranscript(topic: topic, text: committed, speakerLabel: speakerLabel)
            contextManager?.addTranscript(committed)
        }

        guard e.isFinal else { return }

        let finalText = e.text
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = await self.nameDetection.detectAsync(finalText)
                guard result.isDetected else { return }

                if let matched = result.matchedName, !matched.trimmingCharacters(in: .whitespaces).isEmpty,
                   self.currentTopicRef != nil {
                    self.updateTranscriptSpeaker(text: finalText, speaker: matched)
                }

                let now = Date()
                if now.timeIntervalSince(self.lastNameAlertFiredAt) < 5 {
                    return
                }
                self.lastNameAlertFiredAt = now

                let questions = (result.extractedQuestions?.isEmpty == false) ? result.extractedQuestions! : [finalText]

                let history = self.timestampedHistory
                let beforeCount = max(0, history.count - 1)
                let context = history
                    .dropFirst(max(0, beforeCount - 8))
                    .prefix(min(beforeCount, 8))
                    .map { TranscriptContextLine(time: Self.hhmmss.string(from: $0.time), speaker: nil, text: $0.text) }

                var screenshotPath: String? = nil
                do { screenshotPath = try await self.screen.takeScreenshot() } catch {
                }

                self.popups.showNameAlert(NameAlertData(
                    detectedAt: now,
                    quote: finalText,
                    questions: questions,
                    context: Array(context),
                    screenshotPath: screenshotPath))
            } catch {
            }
        }

        transcriptsSinceTopicCheck += 1
        if transcriptsSinceTopicCheck >= 20, !topicDetecting {
            Task { await self.detectTopic() }
        }

        transcriptsSinceConclusionCheck += 1
        if transcriptsSinceConclusionCheck >= 25, !conclusionDetecting {
            Task { await self.detectConclusions() }
        }
    }

    private static var resolvedSelfLabel: String {
        let name = KeychainStorage.load(StoreKeys.userName)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? tr("我", "Me") : name
    }

    private func appendHistory(_ text: String, speaker: String? = nil) {
        let line = (speaker?.isEmpty == false) ? "\(speaker!)：\(text)" : text
        transcriptHistory.append(line)
        timestampedHistory.append((Date(), line))
        if transcriptHistory.count > 200 { transcriptHistory.removeFirst() }
        if timestampedHistory.count > 60 { timestampedHistory.removeFirst() }
    }

    private static let echoWindowSeconds: TimeInterval = 12

    private func recordRemoteUtterance(_ text: String) {
        let now = Date()
        recentRemoteUtterances.removeAll { now.timeIntervalSince($0.time) > Self.echoWindowSeconds }
        recentRemoteUtterances.append((now, text))
        if recentRemoteUtterances.count > 50 { recentRemoteUtterances.removeFirst(recentRemoteUtterances.count - 50) }
    }

    private func isEchoOfRemote(_ text: String) -> Bool {
        let now = Date()
        recentRemoteUtterances.removeAll { now.timeIntervalSince($0.time) > Self.echoWindowSeconds }
        let a = Self.normalizeForEchoCompare(text)
        guard a.count >= 4 else { return false }
        for entry in recentRemoteUtterances {
            let b = Self.normalizeForEchoCompare(entry.text)
            guard b.count >= 4 else { continue }
            if a == b || a.contains(b) || b.contains(a) { return true }
            if Self.echoSimilarity(a, b) >= 0.8 { return true }
        }
        return false
    }

    private static func normalizeForEchoCompare(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(120))
    }

    private static func echoSimilarity(_ a: String, _ b: String) -> Double {
        let ca = Array(a), cb = Array(b)
        let n = ca.count, m = cb.count
        guard n > 0, m > 0 else { return 0 }
        if abs(n - m) > max(n, m) / 4 { return 0 }
        var prev = [Int](0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                curr[j] = ca[i - 1] == cb[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], curr[j - 1]) + 1
            }
            swap(&prev, &curr)
        }
        return 1.0 - Double(prev[m]) / Double(max(n, m))
    }

    private func waitForSelfTestTranscript(timeout: Double) async -> String {
        await withCheckedContinuation { continuation in
            selfTestContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let c = self.selfTestContinuation else { return }
                self.selfTestContinuation = nil
                c.resume(returning: "")
            }
        }
    }

    // MARK: - Screenshot handling

    private func onScreenshot(_ e: ScreenshotCapturedEvent) {
        saveScreenshot(e)
        hasSessionData = true
        contextManager?.addTranscript(Self.hhmmss.string(from: e.timestamp) + tr(" [截图]", " [Screenshot]"))

        guard isMultimodalEnabled, currentTopicRef != nil else { return }
        let filePath = e.filePath
        let topic = currentTopic
        pendingVisionCount += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingVisionCount -= 1 }
            do {
                let ctx = self.contextManager?.buildContextForVision(screenshotTimestamp: e.timestamp)
                let result = try await self.vision.analyzeScreenshot(
                    imagePath: filePath,
                    currentTopic: topic,
                    surroundingTranscripts: ctx?.surroundingTranscripts ?? [])

                self.contextManager?.addScreenshotSummary(
                    aiSummary: result.aiSummary,
                    timeLabel: Self.hhmmss.string(from: e.timestamp))

                if let record = self.sessionScreenshotMap[filePath] {
                    record.aiSummary = result.aiSummary
                    record.meetingRelevance = result.meetingRelevance
                    record.contentType = result.contentType
                    record.ocrText = result.ocrText
                    if let data = try? JSONEncoder().encode(result.keyEntities) {
                        record.keyEntities = String(data: data, encoding: .utf8)
                    }
                    if let data = try? JSONEncoder().encode(result.keyNumbers) {
                        record.keyNumbers = String(data: data, encoding: .utf8)
                    }
                    record.sensitivityLevel = result.sensitivityLevel
                    record.activeSpeakerName = result.activeSpeakerName
                    record.analysisStatus = "ready"
                    DataStore.shared.update(record)
                }

                if let name = result.activeSpeakerName, !name.trimmingCharacters(in: .whitespaces).isEmpty,
                   let currentLabel = self.lastSpeakerLabel,
                   self.pendingSpeakerLabels.remove(currentLabel) != nil,
                   self.speakerNameMap[currentLabel] == nil {
                    self.speakerNameMap[currentLabel] = name
                }
            } catch {
            }
        }
    }

    // MARK: - Topic detection

    private func detectTopic() async {
        if topicDetecting { return }
        topicDetecting = true
        transcriptsSinceTopicCheck = 0
        defer { topicDetecting = false }

        do {
            let recent = getRecentTranscripts(30)
            if recent.count < 5 { return }

            let prompt = tr(
                "根据以下会议对话，用不超过10个字总结当前讨论的核心议题，只返回议题名称：\n",
                "Based on the following meeting conversation, summarize the core topic currently being discussed in no more than 6 words. Return only the topic name:\n")
                + recent.joined(separator: "\n")
            let raw = try await llm.analyze(prompt)
            let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: CharacterSet(charactersIn: "。"))
                .trimmingCharacters(in: .whitespaces)

            if topic.isEmpty || topic.count > 20 { return }


            let current = currentTopic.trimmingCharacters(in: .whitespaces)

            if current.isEmpty {
                currentTopic = topic
                topicFlashId = UUID()
                contextManager?.setCurrentTopic(topic)
                if let t = currentTopicRef {
                    t.title = topic
                    DataStore.shared.update(t)
                }
            } else if current.caseInsensitiveCompare(topic) != .orderedSame {
                await closeCurrentTopic()
                createNewTopic(title: topic)
                currentTopic = topic
                topicFlashId = UUID()
                contextManager?.setCurrentTopic(topic)
                transcriptsSinceTopicCheck = 0
            }
        } catch {
        }
    }

    private func closeCurrentTopic(waitForSummary: Bool = false) async {
        guard let topic = currentTopicRef else { return }
        topic.endTime = Date()
        DataStore.shared.update(topic)

        if waitForSummary {
            if let summary = await generateTopicSummary(topic) {
                topic.summary = summary
                DataStore.shared.update(topic)
            }
        } else {
            Task { [weak self] in
                guard let self else { return }
                if let summary = await self.generateTopicSummary(topic) {
                    topic.summary = summary
                    DataStore.shared.update(topic)
                }
            }
        }
    }

    private func createNewTopic(title: String) {
        guard let session = currentSession else { return }
        let maxOrder = session.topics.map(\.orderIndex).max() ?? -1
        let topic = Topic(title: title, startTime: Date(), orderIndex: maxOrder + 1, session: session)
        DataStore.shared.insert(topic)
        currentTopicRef = topic
    }

    private func generateTopicSummary(_ topic: Topic) async -> String? {
        do {
            let transcripts = topic.transcripts.sorted { $0.timestamp < $1.timestamp }.map(\.text)
            if transcripts.count < 3 { return nil }

            let screenshots = (topic.session?.screenshots ?? [])
                .filter { s in
                    guard s.analysisStatus == "ready" else { return false }
                    guard s.timestamp >= topic.startTime else { return false }
                    if let end = topic.endTime, s.timestamp > end { return false }
                    return true
                }
                .sorted { $0.timestamp < $1.timestamp }

            let prompt = Self.buildTopicSummaryPrompt(topic: topic, transcripts: transcripts,
                decisions: topic.decisions, actions: topic.actionItems, screenshots: screenshots)
            let response = try await withTimeout(30) { [llm] in try await llm.analyze(prompt) }
            return Self.parseSummaryJson(response).summary
        } catch {
            return nil
        }
    }

    private static func buildTopicSummaryPrompt(topic: Topic, transcripts: [String],
                                                decisions: [Decision], actions: [ActionItem],
                                                screenshots: [Screenshot]) -> String {
        let en = AppLanguage.current.isEnglish
        var sb = ""
        sb += en
            ? "You are a meeting notes assistant. Generate a concise summary for the following meeting topic.\n\n"
            : "你是会议记录助手。请为以下会议议题生成简洁摘要。\n\n"
        sb += (en ? "Topic: " : "议题标题：") + topic.title + "\n"
        sb += (en ? "Time range: " : "时间范围：")
            + "\(hhmm.string(from: topic.startTime)) - \(topic.endTime.map { hhmm.string(from: $0) } ?? (en ? "now" : "至今"))\n\n"
        sb += (en ? "[Transcript]\n" : "【对话转录】\n")
        sb += transcripts.joined(separator: "\n") + "\n\n"

        if !decisions.isEmpty {
            sb += en ? "[Related Decisions]\n" : "【相关决策】\n"
            for d in decisions { sb += "- \(d.decisionText)\n" }
            sb += "\n"
        }

        if !actions.isEmpty {
            sb += en ? "[Related Action Items]\n" : "【相关行动项】\n"
            for a in actions {
                sb += "- \(a.assignedTo): \(a.task)" + (a.deadline.map { en ? " (\($0))" : "（\($0)）" } ?? "") + "\n"
            }
            sb += "\n"
        }

        if !screenshots.isEmpty {
            sb += en ? "[Screen Content Analysis]\n" : "【屏幕内容分析】\n"
            for s in screenshots.prefix(5) {
                let summary = s.aiSummary ?? ""
                let ocr = s.ocrText ?? ""
                let type = s.contentType ?? (en ? "unknown" : "未知")
                if en {
                    sb += "[\(hhmmss.string(from: s.timestamp))] type: \(type) | content: \(summary)"
                        + (ocr.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " | OCR: \(ocr)") + "\n"
                } else {
                    sb += "[\(hhmmss.string(from: s.timestamp))] 类型：\(type) | 内容：\(summary)"
                        + (ocr.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " | OCR：\(ocr)") + "\n"
                }
            }
            sb += "\n"
        }

        if en {
            sb += "Return JSON in this format:\n"
            sb += "{\"summary\":\"Summarize the topic's core discussion, key conclusions, and follow-up actions in 2-4 sentences\"}\n"
            sb += "Return JSON only, no Markdown.\n"
        } else {
            sb += "请用JSON格式返回：\n"
            sb += "{\"summary\":\"用2-4句话总结该议题的核心讨论内容、关键结论和后续行动\"}\n"
            sb += "只返回JSON，不要Markdown标记。\n"
        }
        return sb
    }

    // MARK: - Conclusion detection

    private func detectConclusions() async {
        if conclusionDetecting { return }
        conclusionDetecting = true
        transcriptsSinceConclusionCheck = 0
        defer { conclusionDetecting = false }

        do {
            let recent = getRecentTranscripts(40)
            if recent.count < 8 { return }

            let prompt: String
            if AppLanguage.current.isEnglish {
                prompt = """
                Extract clear decisions and action items with a clear owner from the following meeting conversation, and return JSON:
                {"decisions":["decision 1"],"actions":[{"assignedTo":"owner","task":"task","deadline":"deadline or null"}]}
                Return empty arrays if none. Return JSON only, no Markdown.

                Transcript:
                \(recent.joined(separator: "\n"))
                """
            } else {
                prompt = """
                从以下会议对话中提取明确的决策结论和有明确负责人的行动项，以JSON格式返回：
                {"decisions":["决策1"],"actions":[{"assignedTo":"负责人","task":"任务","deadline":"截止时间或null"}]}
                若无则返回空数组。只返回JSON，不要Markdown。

                转录内容：
                \(recent.joined(separator: "\n"))
                """
            }

            let response = try await llm.analyze(prompt)
            let parsed = Self.parseSummaryJson(response)

            if !parsed.decisions.isEmpty {
                let newOnes = parsed.decisions.filter {
                    d in !currentDecisions.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame })
                }
                currentDecisions.append(contentsOf: newOnes)
                if currentDecisions.count > 50 {
                    currentDecisions.removeFirst(currentDecisions.count - 50)
                }
                for d in newOnes { contextManager?.addDecision(d) }
                if !newOnes.isEmpty, let topic = currentTopicRef {
                    saveDecisions(topic: topic, newOnes)
                }
            }

            if !parsed.actions.isEmpty {
                let newActs = parsed.actions.filter {
                    a in !currentActionItems.contains(where: { $0.task.caseInsensitiveCompare(a.task) == .orderedSame })
                }
                currentActionItems.append(contentsOf: newActs)
                if currentActionItems.count > 30 {
                    currentActionItems.removeFirst(currentActionItems.count - 30)
                }
                for a in newActs { contextManager?.addActionItem(task: a.task, assignedTo: a.assignedTo, deadline: a.deadline) }
                if !newActs.isEmpty, let topic = currentTopicRef {
                    saveActionItems(topic: topic, newActs)
                }
            }
        } catch {
        }
    }

    private func saveDecisions(topic: Topic, _ decisions: [String]) {
        for text in decisions {
            DataStore.shared.insert(Decision(timestamp: Date(), decisionText: text, topic: topic))
        }
    }

    private func saveActionItems(topic: Topic, _ items: [(assignedTo: String, task: String, deadline: String?)]) {
        for item in items {
            DataStore.shared.insert(ActionItem(timestamp: Date(), assignedTo: item.assignedTo, task: item.task, deadline: item.deadline, topic: topic))
        }
    }

    // MARK: - DB helpers

    private func createSession(startTime: Date) {
        let session = MeetingSession(startTime: startTime, title: tr("会议 \(Self.monthDayHHmm(startTime))", "Meeting \(Self.monthDayHHmm(startTime))"))
        session.status = .monitoring
        DataStore.shared.insert(session)

        let topic = Topic(title: tr("议题 1", "Topic 1"), startTime: startTime, orderIndex: 0, session: session)
        DataStore.shared.insert(topic)

        currentSession = session
        currentTopicRef = topic
    }

    private func saveTranscript(topic: Topic, text: String, speakerLabel: String?) {
        let record = Transcript(timestamp: Date(), speaker: speakerLabel, text: text, isFinal: true, confidence: 1.0, topic: topic)
        DataStore.shared.insert(record)
        sessionTranscripts.append(record)
        if sessionTranscripts.count > 500 { sessionTranscripts.removeFirst(sessionTranscripts.count - 500) }
    }

    private func updateTranscriptSpeaker(text: String, speaker: String) {
        guard let record = sessionTranscripts.last(where: { $0.text == text }) else { return }
        record.speaker = speaker
        DataStore.shared.update(record)
    }

    private func saveScreenshot(_ e: ScreenshotCapturedEvent) {
        guard let session = currentSession else { return }
        let record = Screenshot(timestamp: e.timestamp, filePath: e.filePath, imageHash: e.imageHash, session: session)
        DataStore.shared.insert(record)
        sessionScreenshotMap[e.filePath] = record
    }

    private func endSession(_ session: MeetingSession, finalTopic: Topic?) async {
        session.endTime = Date()
        session.status = .ended
        DataStore.shared.update(session)
        NotificationCenter.default.post(name: .mmSessionEnded, object: nil)

        if let finalTopic {
            currentTopicRef = finalTopic
            await closeCurrentTopic(waitForSummary: true)
        }

        // Wait for in-flight Vision analyses so the final summary can use them
        if pendingVisionCount > 0 {
            let deadline = Date().addingTimeInterval(20)
            while pendingVisionCount > 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        let topics = session.topics.sorted { $0.orderIndex < $1.orderIndex }
        let screenshots = session.screenshots
            .filter { $0.analysisStatus == "ready" }
            .sorted { $0.timestamp < $1.timestamp }

        var speakerMapping: [String: String] = [:]
        Self.mapSpeakerLabelsToNames(topics: topics, screenshots: screenshots, mapping: &speakerMapping)
        // Fallback: live OCR mapping (single data point) for 发言人N labels the vote
        // couldn't resolve. Never applied to "对方" — a single OCR hit must not pin
        // one name on the whole remote track when there may be several participants.
        for (label, name) in speakerNameMap where speakerMapping[label] == nil
            && (label.hasPrefix("发言人") || label.hasPrefix("Speaker")) {
            speakerMapping[label] = name
        }
        if !speakerMapping.isEmpty {
            for topic in topics {
                for tr in topic.transcripts {
                    if let speaker = tr.speaker, let realName = speakerMapping[speaker] {
                        tr.speaker = realName
                        DataStore.shared.update(tr)
                    }
                }
            }
        }

        if topics.contains(where: { !$0.transcripts.isEmpty }) {
            let prompt = Self.buildFinalSummaryPrompt(session: session, topics: topics, screenshots: screenshots)
            do {
                let response = try await withTimeout(60) { [llm] in try await llm.analyze(prompt) }
                var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if json.hasPrefix("```") {
                    json = json.replacingOccurrences(of: #"^```\w*\n?|\n?```$"#, with: "", options: .regularExpression)
                }
                if let data = json.data(using: .utf8),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    session.summary = root["summary"] as? String
                }
            } catch {
            }
        }

        session.endTime = Date()
        session.status = .ended
        DataStore.shared.update(session)
        NotificationCenter.default.post(name: .mmSessionEnded, object: nil)
    }

    private static func buildFinalSummaryPrompt(session: MeetingSession, topics: [Topic], screenshots: [Screenshot]) -> String {
        var sb = ""

        let en = AppLanguage.current.isEnglish

        let duration: String
        if let end = session.endTime {
            let seconds = Int(end.timeIntervalSince(session.startTime))
            duration = String(format: "%02d:%02d", seconds / 3600, (seconds / 60) % 60)
        } else {
            duration = en ? "unknown" : "未知"
        }

        let fullFormatter = DateFormatter()
        fullFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        if en {
            sb += "You are a meeting minutes assistant. Generate a structured meeting summary based on the complete meeting data below.\n\n"
            sb += "Meeting title: \(session.title ?? "Untitled")\n"
            sb += "Meeting time: \(fullFormatter.string(from: session.startTime)) to \(session.endTime.map { fullFormatter.string(from: $0) } ?? "in progress")\n"
            sb += "Duration: \(duration)\n\n"

            sb += "[Topic Overview]\n"
            for (i, t) in topics.enumerated() {
                sb += "Topic \(i + 1): \(t.title) (\(hhmm.string(from: t.startTime)) - \(t.endTime.map { hhmm.string(from: $0) } ?? "now"))\n"
                if let summary = t.summary, !summary.trimmingCharacters(in: .whitespaces).isEmpty {
                    sb += "  Summary: \(summary)\n"
                }
            }
            sb += "\n"

            let allDecisions = topics.flatMap(\.decisions)
            if !allDecisions.isEmpty {
                sb += "[All Decisions]\n"
                for d in allDecisions { sb += "- \(d.decisionText)\n" }
                sb += "\n"
            }

            let allActions = topics.flatMap(\.actionItems)
            if !allActions.isEmpty {
                sb += "[All Action Items]\n"
                for a in allActions {
                    sb += "- \(a.assignedTo): \(a.task)" + (a.deadline.map { " (\($0))" } ?? "") + "\n"
                }
                sb += "\n"
            }

            let relevantShots = screenshots.filter { $0.meetingRelevance == "high" || $0.meetingRelevance == "medium" }
            if !relevantShots.isEmpty {
                sb += "[Screen Content Analysis] (key screenshots during the meeting)\n"
                var charCount = 0
                for s in relevantShots {
                    var line = "[\(hhmmss.string(from: s.timestamp))] type: \(s.contentType ?? "unknown") | content: \(s.aiSummary ?? "")"
                    if let ocr = s.ocrText, !ocr.trimmingCharacters(in: .whitespaces).isEmpty {
                        line += " | key text: \(ocr)"
                    }
                    if let entities = s.keyEntities, !entities.isEmpty {
                        line += " | key entities: \(entities)"
                    }
                    if let numbers = s.keyNumbers, !numbers.isEmpty {
                        line += " | key numbers: \(numbers)"
                    }
                    if charCount + line.count > 4000 { break }
                    sb += line + "\n"
                    charCount += line.count + 1
                }
                sb += "\n"
            }

            sb += "Generate a complete meeting summary and return JSON in this format:\n"
            sb += "{\n"
            sb += "  \"summary\": \"A 3-5 sentence overall summary covering the meeting's goals, discussion points, and key outcomes\",\n"
            sb += "  \"key_highlights\": [\"highlight 1\", \"highlight 2\", \"highlight 3\"],\n"
            sb += "  \"next_steps\": [\"suggested follow-up 1\", \"suggested follow-up 2\"]\n"
            sb += "}\n"
            sb += "Return JSON only, no Markdown.\n"
            return sb
        }

        sb += "你是会议纪要助手。请根据以下完整的会议数据生成一份结构化的会议总结。\n\n"
        sb += "会议标题：\(session.title ?? "未命名")\n"
        sb += "会议时间：\(fullFormatter.string(from: session.startTime)) 至 \(session.endTime.map { fullFormatter.string(from: $0) } ?? "进行中")\n"
        sb += "会议时长：\(duration)\n\n"

        sb += "【议题概览】\n"
        for (i, t) in topics.enumerated() {
            sb += "议题\(i + 1)：\(t.title)（\(hhmm.string(from: t.startTime)) - \(t.endTime.map { hhmm.string(from: $0) } ?? "至今")）\n"
            if let summary = t.summary, !summary.trimmingCharacters(in: .whitespaces).isEmpty {
                sb += "  摘要：\(summary)\n"
            }
        }
        sb += "\n"

        let allDecisions = topics.flatMap(\.decisions)
        if !allDecisions.isEmpty {
            sb += "【所有决策】\n"
            for d in allDecisions { sb += "- \(d.decisionText)\n" }
            sb += "\n"
        }

        let allActions = topics.flatMap(\.actionItems)
        if !allActions.isEmpty {
            sb += "【所有行动项】\n"
            for a in allActions {
                sb += "- \(a.assignedTo)：\(a.task)" + (a.deadline.map { "（\($0)）" } ?? "") + "\n"
            }
            sb += "\n"
        }

        let relevantShots = screenshots.filter { $0.meetingRelevance == "high" || $0.meetingRelevance == "medium" }
        if !relevantShots.isEmpty {
            sb += "【屏幕内容分析】（会议期间关键截图）\n"
            var charCount = 0
            for s in relevantShots {
                var line = "[\(hhmmss.string(from: s.timestamp))] 类型：\(s.contentType ?? "未知") | 内容：\(s.aiSummary ?? "")"
                if let ocr = s.ocrText, !ocr.trimmingCharacters(in: .whitespaces).isEmpty {
                    line += " | 关键文字：\(ocr)"
                }
                if let entities = s.keyEntities, !entities.isEmpty {
                    line += " | 关键实体：\(entities)"
                }
                if let numbers = s.keyNumbers, !numbers.isEmpty {
                    line += " | 关键数据：\(numbers)"
                }
                if charCount + line.count > 4000 { break }
                sb += line + "\n"
                charCount += line.count + 1
            }
            sb += "\n"
        }

        sb += "请生成一份完整的会议总结，用JSON格式返回：\n"
        sb += "{\n"
        sb += "  \"summary\": \"3-5句话的整体会议概述，涵盖会议目标、讨论要点、核心成果\",\n"
        sb += "  \"key_highlights\": [\"要点1\", \"要点2\", \"要点3\"],\n"
        sb += "  \"next_steps\": [\"后续行动建议1\", \"后续行动建议2\"]\n"
        sb += "}\n"
        sb += "只返回JSON，不要Markdown标记。\n"
        return sb
    }

    /// Resolves anonymous/ambiguous speaker labels (发言人N, 对方) to real names
    /// by correlating every labeled transcript timestamp with nearby screenshot
    /// OCR results using a distance-weighted majority vote. A label is only
    /// mapped when the winning name has a clear margin (1.5×); ambiguous labels
    /// stay unmapped for manual correction. For "对方" this means a name is only
    /// assigned when the remote side consistently appears to be one person.
    private static func mapSpeakerLabelsToNames(topics: [Topic], screenshots: [Screenshot], mapping: inout [String: String]) {
        let selfLabel = resolvedSelfLabel
        let labelTimestamps = topics
            .flatMap(\.transcripts)
            .filter { tr in
                guard let speaker = tr.speaker, speaker != selfLabel else { return false }
                let resolvable = speaker.hasPrefix("发言人") || speaker.hasPrefix("Speaker")
                    || speaker == "对方" || speaker == "Remote"
                return resolvable && mapping[speaker] == nil
            }
            .map { (label: $0.speaker!, timestamp: $0.timestamp) }

        if labelTimestamps.isEmpty { return }

        let nameShots = screenshots
            .filter { !($0.activeSpeakerName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
            .sorted { $0.timestamp < $1.timestamp }
        if nameShots.isEmpty { return }

        for label in Set(labelTimestamps.map(\.label)) {
            var votes: [String: Double] = [:]
            for ts in labelTimestamps.filter({ $0.label == label }).map(\.timestamp) {
                var nearestName: String? = nil
                var bestDistance = 60.0
                for shot in nameShots {
                    let dist = abs(shot.timestamp.timeIntervalSince(ts))
                    if dist < bestDistance {
                        bestDistance = dist
                        nearestName = shot.activeSpeakerName
                    }
                }
                if let name = nearestName {
                    // Closer screenshots vote heavier (weight 1.0 at 0s → ~0.14 at 60s)
                    votes[name, default: 0] += 1.0 / (1.0 + bestDistance / 10.0)
                }
            }
            let ranked = votes.sorted { $0.value > $1.value }
            guard let winner = ranked.first else { continue }
            let clear = ranked.count == 1 || winner.value >= ranked[1].value * 1.5
            if clear {
                mapping[label] = winner.key
            }
        }
    }

    // MARK: - Helpers

    struct TimeoutError: Error {}

    func withTimeout<T>(_ seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return result
        }
    }

    private static func monthDayHHmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
