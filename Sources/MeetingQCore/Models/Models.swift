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

public enum SessionStatus: String, Codable, Sendable {
    case idle, monitoring, ended, saved
}

public enum QuestionType: String, Codable, Sendable {
    case direct, indirect, actionRequired
}

public enum QuestionStatus: String, Codable, Sendable {
    case pending, acknowledged, dismissed
}

public final class MeetingSession {
    public var id: Int64 = 0
    public var startTime: Date
    public var endTime: Date?
    public var statusRaw: String = SessionStatus.idle.rawValue
    public var title: String?
    public var summary: String?
    public var themeId: Int64?
    public var meetingType: String?
    public var templateId: String?
    public var qualityScore: Int?
    public var qualityIssues: String?
    public var minutesJson: String?
    public var topics: [Topic] = []
    public var screenshots: [Screenshot] = []

    public init(startTime: Date = Date(), title: String? = nil) {
        self.startTime = startTime
        self.title = title
    }

    public var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .idle }
        set { statusRaw = newValue.rawValue }
    }
}

public final class Topic {
    public var id: Int64 = 0
    public var title: String
    public var startTime: Date
    public var endTime: Date?
    public var orderIndex: Int
    public var summary: String?
    public weak var session: MeetingSession?
    public var sessionId: Int64 = 0
    public var transcripts: [Transcript] = []
    public var decisions: [Decision] = []
    public var questions: [Question] = []
    public var actionItems: [ActionItem] = []

    public init(title: String, startTime: Date = Date(), orderIndex: Int = 0, session: MeetingSession? = nil) {
        self.title = title
        self.startTime = startTime
        self.orderIndex = orderIndex
        self.session = session
        self.sessionId = session?.id ?? 0
    }
}

public final class Transcript {
    public var id: Int64 = 0
    public var timestamp: Date
    public var speaker: String?
    public var text: String
    public var isFinal: Bool
    public var confidence: Float
    public weak var topic: Topic?
    public var topicId: Int64 = 0

    public init(timestamp: Date = Date(), speaker: String? = nil, text: String, isFinal: Bool, confidence: Float, topic: Topic? = nil) {
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.topic = topic
        self.topicId = topic?.id ?? 0
    }
}

public final class Screenshot {
    public var id: Int64 = 0
    public var timestamp: Date
    public var filePath: String
    public var imageHash: String?
    public var aiSummary: String?
    public var ocrText: String?
    public var contentType: String?
    public var keyEntities: String?
    public var keyNumbers: String?
    public var keyDates: String?
    public var slideDecisions: String?
    public var slideActionItems: String?
    public var chartType: String?
    public var chartInsight: String?
    public var meetingRelevance: String?
    public var sensitivityLevel: String?
    public var analysisStatus: String?
    public var activeSpeakerName: String?
    public weak var session: MeetingSession?
    public var sessionId: Int64 = 0

    public init(timestamp: Date = Date(), filePath: String, imageHash: String? = nil, session: MeetingSession? = nil) {
        self.timestamp = timestamp
        self.filePath = filePath
        self.imageHash = imageHash
        self.session = session
        self.sessionId = session?.id ?? 0
    }
}

public final class Decision {
    public var id: Int64 = 0
    public var timestamp: Date
    public var decisionText: String
    public var sourceSpeaker: String?
    public weak var topic: Topic?
    public var topicId: Int64 = 0

    public init(timestamp: Date = Date(), decisionText: String, topic: Topic? = nil) {
        self.timestamp = timestamp
        self.decisionText = decisionText
        self.topic = topic
        self.topicId = topic?.id ?? 0
    }
}

public final class Question {
    public var id: Int64 = 0
    public var timestamp: Date
    public var speaker: String?
    public var originalText: String = ""
    public var extractedQuestions: String?
    public var questionTypeRaw: String = QuestionType.direct.rawValue
    public var confidence: Float = 0
    public var statusRaw: String = QuestionStatus.pending.rawValue
    public weak var topic: Topic?
    public var topicId: Int64 = 0

    public init(timestamp: Date = Date(), speaker: String? = nil, originalText: String, topic: Topic? = nil) {
        self.timestamp = timestamp
        self.speaker = speaker
        self.originalText = originalText
        self.topic = topic
        self.topicId = topic?.id ?? 0
    }

    public var questionType: QuestionType {
        get { QuestionType(rawValue: questionTypeRaw) ?? .direct }
        set { questionTypeRaw = newValue.rawValue }
    }

    public var status: QuestionStatus {
        get { QuestionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
}

public enum ActionItemStatus: String, Codable, Sendable, CaseIterable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case complete
}

public final class ActionItem {
    public var id: Int64 = 0
    public var timestamp: Date
    public var assignedTo: String
    public var task: String
    public var deadline: String?
    public var statusRaw: String = ActionItemStatus.notStarted.rawValue
    public var priority: String?
    public var sourceSpeaker: String?
    public weak var topic: Topic?
    public var topicId: Int64 = 0

    public init(timestamp: Date = Date(), assignedTo: String, task: String, deadline: String? = nil, topic: Topic? = nil) {
        self.timestamp = timestamp
        self.assignedTo = assignedTo
        self.task = task
        self.deadline = deadline
        self.topic = topic
        self.topicId = topic?.id ?? 0
    }

    public var status: ActionItemStatus {
        get { ActionItemStatus(rawValue: statusRaw) ?? .notStarted }
        set { statusRaw = newValue.rawValue }
    }

    public var isOverdue: Bool {
        guard status != .complete, let deadline, !deadline.isEmpty else { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let due = f.date(from: String(deadline.prefix(10))) else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }
}

public final class MeetingTheme {
    public var id: Int64 = 0
    public var name: String
    public var keywords: [String] = []
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var archived: Bool = false

    public init(name: String, keywords: [String] = []) {
        self.name = name
        self.keywords = keywords
    }

    public var keywordsJoined: String {
        get { keywords.joined(separator: ",") }
        set { keywords = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }
}
