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

import Foundation

public struct ScreenshotSummary: Sendable {
    public var aiSummary: String
    public var timeLabel: String

    public init(aiSummary: String, timeLabel: String) {
        self.aiSummary = aiSummary
        self.timeLabel = timeLabel
    }
}

public struct ActionItemEntry: Sendable, Equatable {
    public var task: String
    public var assignedTo: String
    public var deadline: String?

    public init(task: String, assignedTo: String, deadline: String? = nil) {
        self.task = task
        self.assignedTo = assignedTo
        self.deadline = deadline
    }
}

public struct MultimodalContext: Sendable {
    public var meetingTitle: String = ""
    public var participants: [String] = []
    public var currentTopic: String = ""
    public var compressedHistory: String = ""
    public var screenshotSummaries: [ScreenshotSummary] = []
    public var transcripts: [String] = []
    public var decisions: [String] = []
    public var actionItems: [ActionItemEntry] = []

    public init() {}
}

public struct VisionContext: Sendable {
    public var meetingTitle: String = ""
    public var currentTopic: String = ""
    public var surroundingTranscripts: [String] = []

    public init() {}
}

public final class ContextWindowManager {
    public static let maxTranscripts = 25
    public static let maxScreenshots = 3
    public static let maxDecisions = 10
    public static let maxActionItems = 10

    private var recentTranscripts: [String] = []
    private var recentScreenshots: [ScreenshotSummary] = []
    private var decisions: [String] = []
    private var actionItems: [ActionItemEntry] = []
    private var compressedHistory = ""
    private var currentTopic = ""
    private var meetingTitle = ""
    private var participants: [String] = []

    public init() {}

    public func addTranscript(_ text: String) {
        recentTranscripts.append(text)
        if recentTranscripts.count > Self.maxTranscripts {
            recentTranscripts.removeFirst()
        }
    }

    public func addScreenshotSummary(aiSummary: String, timeLabel: String) {
        recentScreenshots.append(ScreenshotSummary(aiSummary: aiSummary, timeLabel: timeLabel))
        if recentScreenshots.count > Self.maxScreenshots {
            recentScreenshots.removeFirst()
        }
    }

    public func setCompressedHistory(_ history: String) { compressedHistory = history }

    public func setCurrentTopic(_ topic: String) { currentTopic = topic }

    public func setMeetingTitle(_ title: String) { meetingTitle = title }

    public func addParticipant(_ name: String) {
        if !participants.contains(name) {
            participants.append(name)
        }
    }

    public func addDecision(_ decision: String) {
        if !decisions.contains(decision) {
            decisions.append(decision)
            if decisions.count > Self.maxDecisions {
                decisions.removeFirst()
            }
        }
    }

    public func addActionItem(task: String, assignedTo: String, deadline: String?) {
        if !actionItems.contains(where: { $0.task == task }) {
            actionItems.append(ActionItemEntry(task: task, assignedTo: assignedTo, deadline: deadline))
            if actionItems.count > Self.maxActionItems {
                actionItems.removeFirst()
            }
        }
    }

    public func clearScreenshots() { recentScreenshots.removeAll() }

    public func clear() {
        recentTranscripts.removeAll()
        recentScreenshots.removeAll()
        decisions.removeAll()
        actionItems.removeAll()
        compressedHistory = ""
        currentTopic = ""
        meetingTitle = ""
        participants.removeAll()
    }

    public func buildContext() -> MultimodalContext {
        var ctx = MultimodalContext()
        ctx.meetingTitle = meetingTitle
        ctx.participants = participants
        ctx.currentTopic = currentTopic
        ctx.compressedHistory = compressedHistory
        ctx.screenshotSummaries = recentScreenshots
        ctx.transcripts = recentTranscripts
        ctx.decisions = decisions
        ctx.actionItems = actionItems
        return ctx
    }

    public func buildContextForVision(screenshotTimestamp: Date) -> VisionContext {
        var ctx = VisionContext()
        ctx.currentTopic = currentTopic
        ctx.meetingTitle = meetingTitle
        ctx.surroundingTranscripts = Array(recentTranscripts.suffix(8))
        return ctx
    }
}
