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

import AVFAudio
import Foundation

public struct TranscriptEvent: Sendable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Float
    public let utteranceId: Int
    public let speakerLabel: String?

    public init(text: String, isFinal: Bool, confidence: Float, utteranceId: Int = -1, speakerLabel: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.utteranceId = utteranceId
        self.speakerLabel = speakerLabel
    }
}

public protocol AsrService: AnyObject {
    var onTranscript: ((TranscriptEvent) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var isConnected: Bool { get }

    func connect() async throws
    func sendAudio(_ buffer: AVAudioPCMBuffer) async
    func finalizeSegment() async throws
    func disconnect() async
}

public protocol AudioCaptureService: AnyObject {
    var onAudioData: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onSpeechSegmentEnded: (() -> Void)? { get set }
    var isCapturing: Bool { get }
    var currentDeviceName: String? { get }

    func start() async throws
    func stop() async
    func setAsr(_ asr: AsrService?)
}

public protocol LlmService: AnyObject {
    func analyze(_ prompt: String) async throws -> String
    func summarize(_ transcripts: [Transcript]) async throws -> String
    func test() async throws -> String
    func analyzeImage(systemPrompt: String, userMessage: String, imageBase64: String, modelOverride: String?) async throws -> String
}

public struct DetectionResult: Sendable {
    public var isDetected: Bool = false
    public var confidence: Float = 0
    public var matchedName: String?
    public var originalText: String?
    public var extractedQuestions: [String]?
    public var detectionLayer: Int = 0

    public init() {}
}

public protocol NameDetectionService: AnyObject {
    func detect(_ text: String) -> DetectionResult
    func detectAsync(_ text: String) async -> DetectionResult
    func reloadNames()
}

public struct ScreenshotCapturedEvent: Sendable {
    public let filePath: String
    public let timestamp: Date
    public let imageHash: String

    public init(filePath: String, timestamp: Date, imageHash: String) {
        self.filePath = filePath
        self.timestamp = timestamp
        self.imageHash = imageHash
    }
}

public protocol ScreenCaptureService: AnyObject {
    var onScreenshot: ((ScreenshotCapturedEvent) -> Void)? { get set }
    var isCapturing: Bool { get }

    func start(windowID: CGWindowID?) async throws
    func stop() async
    func resetDuplicateState()
    @discardableResult func takeScreenshot() async throws -> String
}

public struct VisionAnalysisResult: Sendable {
    public var aiSummary: String = ""
    public var contentType: String = "other"
    public var keyEntities: [String] = []
    public var keyNumbers: [String] = []
    public var ocrText: String = ""
    public var meetingRelevance: String = "medium"
    public var sensitivityLevel: String = "low"
    public var activeSpeakerName: String?

    public init() {}
}

public protocol VisionService: AnyObject {
    func analyzeScreenshot(imagePath: String, currentTopic: String?, surroundingTranscripts: [String]) async throws -> VisionAnalysisResult
    func testConnection() async throws -> Bool
}
