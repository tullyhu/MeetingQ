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

public final class LegacySpeechRecognizerService: AsrService {
    public var onTranscript: ((TranscriptEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let lock = NSLock()
    private var _isConnected = false
    private var _lastResultTime: Date?

    public var isConnected: Bool { lock.withLock { _isConnected } }
    public var lastResultTime: Date? { lock.withLock { _lastResultTime } }

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var utteranceCounter = 0
    private var manualDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var needsNewRequest = true

    public init() {}

    public func connect() async throws {
        await teardownSession()
        lock.withLock { manualDisconnect = false }

        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            throw AsrError.permissionDenied
        }

        let preferredId = AppLanguage.current.speechLocaleIdentifier
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: preferredId)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw AsrError.unsupported
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AsrError.unsupported
        }

        lock.withLock {
            self.recognizer = recognizer
            needsNewRequest = true
            _isConnected = true
        }
    }

    public func sendAudio(_ buffer: AVAudioPCMBuffer) async {
        guard isConnected else { return }
        startRequestIfNeeded()
        let req = lock.withLock { request }
        req?.append(buffer)
    }

    public func finalizeSegment() async throws {
        let (req, task) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            let r = (request, recognitionTask)
            request = nil
            recognitionTask = nil
            needsNewRequest = true
            return r
        }
        req?.endAudio()
        _ = task
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

    private func startRequestIfNeeded() {
        let recognizer = lock.withLock { () -> SFSpeechRecognizer? in
            guard needsNewRequest, request == nil else { return nil }
            return self.recognizer
        }
        guard let recognizer else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true

        let uid = lock.withLock { utteranceCounter }
        let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                if isFinal {
                    self.lock.withLock {
                        self.utteranceCounter += 1
                        self._lastResultTime = Date()
                        if req === self.request {
                            self.request = nil
                            self.recognitionTask = nil
                            self.needsNewRequest = true
                        }
                    }
                } else {
                    self.lock.withLock { self._lastResultTime = Date() }
                }
                guard !text.isEmpty else { return }
                self.onTranscript?(TranscriptEvent(text: text, isFinal: isFinal,
                                                   confidence: isFinal ? 1.0 : 0.5,
                                                   utteranceId: uid))
            }
            if let error {
                let nsError = error as NSError
                let isCancellation = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                    || nsError.localizedDescription.localizedCaseInsensitiveContains("cancel")
                let shouldReport = self.lock.withLock { () -> Bool in
                    if req === self.request {
                        self.request = nil
                        self.recognitionTask = nil
                        self.needsNewRequest = true
                    }
                    return !self.manualDisconnect && !isCancellation
                }
                if shouldReport {
                    self.handleStreamError(error)
                }
            }
        }

        lock.withLock {
            guard needsNewRequest, self.request == nil, _isConnected else { return }
            self.request = req
            self.recognitionTask = task
            needsNewRequest = false
        }
    }

    private func teardownSession() async {
        let (request, task) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            let t = (self.request, self.recognitionTask)
            self.request = nil
            self.recognitionTask = nil
            self.recognizer = nil
            needsNewRequest = true
            _isConnected = false
            return t
        }
        request?.endAudio()
        task?.cancel()
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
