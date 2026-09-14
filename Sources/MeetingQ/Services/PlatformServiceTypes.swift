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

import CoreGraphics
import Foundation

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
    public var keyDates: [String] = []
    public var slideDecisions: [String] = []
    public var slideActionItems: [String] = []
    public var chartType: String?
    public var chartInsight: String?
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

public protocol LocalOcrService: AnyObject, Sendable {
    func recognizeText(imagePath: String) async throws -> String
}
