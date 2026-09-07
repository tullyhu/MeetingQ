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

import AVFAudio
import Foundation
import Speech

public enum AsrError: LocalizedError {
    case unsupported
    case permissionDenied
    case modelDownloadFailed

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return tr("此设备不支持本地语音识别", "On-device speech recognition is not supported on this device")
        case .permissionDenied:
            return tr("需要语音识别权限，请在系统设置→隐私与安全性→语音识别中允许 MeetingQ",
                      "Speech recognition permission is required. Allow MeetingQ in System Settings → Privacy & Security → Speech Recognition")
        case .modelDownloadFailed:
            return tr("语音模型下载失败，请检查网络后重试", "Failed to download the speech model. Check your network and try again")
        }
    }
}

@available(macOS 26.0, *)
public final class SpeechTranscriberService: AsrService {
    private static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    public var onTranscript: ((TranscriptEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let lock = NSLock()
    private var _isConnected = false
    private var _lastResultTime: Date?

    public var isConnected: Bool { lock.withLock { _isConnected } }
    public var lastResultTime: Date? { lock.withLock { _lastResultTime } }

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var utteranceCounter = 0
    private var manualDisconnect = false

    public init() {}

    public func connect() async throws {
        await teardownSession()
        lock.withLock { manualDisconnect = false }

        guard SpeechTranscriber.isAvailable else {
            throw AsrError.unsupported
        }

        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            throw AsrError.permissionDenied
        }

        let preferredId = AppLanguage.current.isEnglish ? "en-US" : "zh-CN"
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: preferredId))
            ?? Locale(identifier: preferredId)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        var status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            status = await AssetInventory.status(forModules: [transcriber])
            guard status == .installed else {
                throw AsrError.modelDownloadFailed
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        var converter: AVAudioConverter?
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            converter = AVAudioConverter(from: Self.inputFormat, to: best)
        } else {
        }

        lock.withLock {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.continuation = continuation
            self.converter = converter
            _isConnected = true
        }

        analyzerTask = Task { [weak self, analyzer] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                self?.handleStreamError(error)
            }
        }

        resultsTask = Task { [weak self, transcriber] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    if Task.isCancelled { break }
                    self.handleResult(result)
                }
            } catch {
                if !Task.isCancelled {
                    self.handleStreamError(error)
                }
            }
        }

    }

    public func sendAudio(_ buffer: AVAudioPCMBuffer) async {
        let (continuation, converter) = lock.withLock { (self.continuation, self.converter) }
        guard let continuation else { return }
        var output = buffer
        if let converter {
            guard let converted = PcmConverter.convert(converter, input: buffer) else { return }
            output = converted
        }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    public func finalizeSegment() async throws {
    }

    public func disconnect() async {
        lock.withLock { manualDisconnect = true }
        let reconnect = lock.withLock { () -> Task<Void, Never>? in
            let t = reconnectTask
            reconnectTask = nil
            return t
        }
        reconnect?.cancel()
        await teardownSession()
    }

    private func teardownSession() async {
        let (continuation, analyzer, analyzerTask, resultsTask) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Never>?, Task<Void, Never>?) in
            let t = (self.continuation, self.analyzer, self.analyzerTask, self.resultsTask)
            self.continuation = nil
            self.analyzer = nil
            self.transcriber = nil
            self.converter = nil
            self.analyzerTask = nil
            self.resultsTask = nil
            _isConnected = false
            return t
        }
        continuation?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        resultsTask?.cancel()
        analyzerTask?.cancel()
    }

    private func handleResult(_ result: SpeechTranscriber.Result) {
        guard isConnected else { return }
        let text = String(result.text.characters)
        let isFinal = result.isFinal

        var confidence: Double?
        for run in result.text.runs {
            if let c = run.transcriptionConfidence {
                confidence = max(confidence ?? 0, c)
            }
        }
        let conf = Float(confidence ?? (isFinal ? 1.0 : 0.5))

        let uid = lock.withLock { () -> Int in
            let id = utteranceCounter
            if isFinal { utteranceCounter += 1 }
            _lastResultTime = Date()
            return id
        }

        guard !text.isEmpty else { return }
        onTranscript?(TranscriptEvent(text: text, isFinal: isFinal, confidence: conf, utteranceId: uid))
    }

    private func handleStreamError(_ error: Error) {
        let manual = lock.withLock { manualDisconnect }
        guard !manual else { return }
        onError?(error.localizedDescription)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let already = lock.withLock { () -> Bool in
            if manualDisconnect || reconnectTask != nil { return true }
            return false
        }
        guard !already else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                do {
                    try await self.connect()
                    self.lock.withLock { self.reconnectTask = nil }
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.onError?(tr("ASR 自动重连失败(\(attempt)/3): \(error.localizedDescription)",
                                     "ASR auto-reconnect failed (\(attempt)/3): \(error.localizedDescription)"))
                }
            }
            self.lock.withLock {
                self.reconnectTask = nil
                _isConnected = false
            }
        }
        lock.withLock { reconnectTask = task }
    }
}
