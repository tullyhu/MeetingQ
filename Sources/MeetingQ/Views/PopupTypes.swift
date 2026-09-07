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

import Foundation

public struct TranscriptContextLine: Sendable, Equatable {
    public let time: String
    public let speaker: String?
    public let text: String

    public init(time: String, speaker: String?, text: String) {
        self.time = time
        self.speaker = speaker
        self.text = text
    }
}

public struct NameAlertData: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let detectedAt: Date
    public let quote: String
    public let questions: [String]
    public let context: [TranscriptContextLine]
    public let screenshotPath: String?
    public var isPinned: Bool

    public init(detectedAt: Date = Date(), quote: String, questions: [String], context: [TranscriptContextLine], screenshotPath: String?, isPinned: Bool = false) {
        self.id = UUID()
        self.detectedAt = detectedAt
        self.quote = quote
        self.questions = questions
        self.context = context
        self.screenshotPath = screenshotPath
        self.isPinned = isPinned
    }
}

public struct QuickSummaryData: Sendable, Equatable {
    public var isLoading: Bool
    public var topic: String
    public var summary: String
    public var decisions: [String]
    public var actionItems: [String]

    public init(isLoading: Bool = true, topic: String = "", summary: String = "", decisions: [String] = [], actionItems: [String] = []) {
        self.isLoading = isLoading
        self.topic = topic
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
    }
}

@MainActor
public protocol PopupManaging: AnyObject {
    func showNameAlert(_ data: NameAlertData)
    func dismissNameAlert(id: UUID)
    func toggleNameAlertPin(id: UUID)
    func showQuickSummary(_ data: QuickSummaryData)
    func updateQuickSummary(_ data: QuickSummaryData)
    func dismissQuickSummary()
    func showScreenshotAlbum()
}
