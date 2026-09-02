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
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class DataStore {
    public static let shared = DataStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "calledme.db")

    private init() {
        StorageConfig.ensureAccessible(StorageConfig.storageDir)
        let path = StorageConfig.databasePath
        if sqlite3_open(path, &db) != SQLITE_OK {
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA foreign_keys=ON")
        createSchema()
    }

    private var lastError: String {
        guard let db, let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        queue.sync {
            sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time REAL NOT NULL,
            end_time REAL,
            status TEXT NOT NULL DEFAULT 'idle',
            title TEXT,
            summary TEXT)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS topics(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            start_time REAL NOT NULL,
            end_time REAL,
            order_index INTEGER NOT NULL DEFAULT 0,
            summary TEXT)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            speaker TEXT,
            text TEXT NOT NULL,
            is_final INTEGER NOT NULL DEFAULT 0,
            confidence REAL NOT NULL DEFAULT 0)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS screenshots(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            file_path TEXT NOT NULL,
            image_hash TEXT,
            ai_summary TEXT,
            ocr_text TEXT,
            content_type TEXT,
            key_entities TEXT,
            key_numbers TEXT,
            meeting_relevance TEXT,
            sensitivity_level TEXT,
            analysis_status TEXT,
            active_speaker_name TEXT)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS decisions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            decision_text TEXT NOT NULL)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS questions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            speaker TEXT,
            original_text TEXT NOT NULL,
            extracted_questions TEXT,
            question_type TEXT,
            confidence REAL NOT NULL DEFAULT 0,
            status TEXT)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS action_items(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            assigned_to TEXT NOT NULL,
            task TEXT NOT NULL,
            deadline TEXT)
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_topics_session ON topics(session_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_transcripts_topic ON transcripts(topic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_screenshots_session ON screenshots(session_id)")
        exec("""
        CREATE TABLE IF NOT EXISTS themes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            keywords TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0)
        """)
        migrate("ALTER TABLE sessions ADD COLUMN theme_id INTEGER REFERENCES themes(id) ON DELETE SET NULL")
        migrate("ALTER TABLE sessions ADD COLUMN meeting_type TEXT")
        migrate("ALTER TABLE sessions ADD COLUMN template_id TEXT")
        migrate("ALTER TABLE sessions ADD COLUMN quality_score INTEGER")
        migrate("ALTER TABLE sessions ADD COLUMN quality_issues TEXT")
        migrate("ALTER TABLE sessions ADD COLUMN minutes_json TEXT")
        migrate("ALTER TABLE action_items ADD COLUMN status TEXT NOT NULL DEFAULT 'not_started'")
        migrate("ALTER TABLE action_items ADD COLUMN priority TEXT")
        migrate("ALTER TABLE action_items ADD COLUMN source_speaker TEXT")
        migrate("ALTER TABLE decisions ADD COLUMN source_speaker TEXT")
        migrate("ALTER TABLE screenshots ADD COLUMN key_dates TEXT")
        migrate("ALTER TABLE screenshots ADD COLUMN slide_decisions TEXT")
        migrate("ALTER TABLE screenshots ADD COLUMN slide_action_items TEXT")
        migrate("ALTER TABLE screenshots ADD COLUMN chart_type TEXT")
        migrate("ALTER TABLE screenshots ADD COLUMN chart_insight TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_theme ON sessions(theme_id)")
    }

    private func migrate(_ sql: String) {
        queue.sync {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date?) {
        if let value {
            sqlite3_bind_double(stmt, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            bind(stmt)
            if sqlite3_step(stmt) != SQLITE_DONE {
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    private func query<T>(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil, map: (OpaquePointer?) -> T) -> [T] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            bind?(stmt)
            var out: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(map(stmt))
            }
            return out
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func date(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    public func insert(_ s: MeetingSession) {
        s.id = run("INSERT INTO sessions(start_time,end_time,status,title,summary,theme_id,meeting_type,template_id,quality_score,quality_issues,minutes_json) VALUES(?,?,?,?,?,?,?,?,?,?,?)") { stmt in
            bind(stmt, 1, s.startTime)
            bind(stmt, 2, s.endTime)
            bind(stmt, 3, s.statusRaw)
            bind(stmt, 4, s.title)
            bind(stmt, 5, s.summary)
            if let themeId = s.themeId { sqlite3_bind_int64(stmt, 6, themeId) } else { sqlite3_bind_null(stmt, 6) }
            bind(stmt, 7, s.meetingType)
            bind(stmt, 8, s.templateId)
            if let q = s.qualityScore { sqlite3_bind_int64(stmt, 9, Int64(q)) } else { sqlite3_bind_null(stmt, 9) }
            bind(stmt, 10, s.qualityIssues)
            bind(stmt, 11, s.minutesJson)
        }
    }

    public func insert(_ t: Topic) {
        let sessionId = t.session?.id ?? t.sessionId
        t.id = run("INSERT INTO topics(session_id,title,start_time,end_time,order_index,summary) VALUES(?,?,?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, sessionId)
            bind(stmt, 2, t.title)
            bind(stmt, 3, t.startTime)
            bind(stmt, 4, t.endTime)
            sqlite3_bind_int64(stmt, 5, Int64(t.orderIndex))
            bind(stmt, 6, t.summary)
        }
        t.sessionId = sessionId
        if let session = t.session, !session.topics.contains(where: { $0 === t }) {
            session.topics.append(t)
        }
    }

    public func insert(_ t: Transcript) {
        let topicId = t.topic?.id ?? t.topicId
        t.id = run("INSERT INTO transcripts(topic_id,timestamp,speaker,text,is_final,confidence) VALUES(?,?,?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, topicId)
            bind(stmt, 2, t.timestamp)
            bind(stmt, 3, t.speaker)
            bind(stmt, 4, t.text)
            sqlite3_bind_int(stmt, 5, t.isFinal ? 1 : 0)
            sqlite3_bind_double(stmt, 6, Double(t.confidence))
        }
        t.topicId = topicId
        if let topic = t.topic, !topic.transcripts.contains(where: { $0 === t }) {
            topic.transcripts.append(t)
        }
    }

    public func insert(_ s: Screenshot) {
        let sessionId = s.session?.id ?? s.sessionId
        s.id = run("INSERT INTO screenshots(session_id,timestamp,file_path,image_hash,analysis_status) VALUES(?,?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, sessionId)
            bind(stmt, 2, s.timestamp)
            bind(stmt, 3, s.filePath)
            bind(stmt, 4, s.imageHash)
            bind(stmt, 5, s.analysisStatus)
        }
        s.sessionId = sessionId
        if let session = s.session, !session.screenshots.contains(where: { $0 === s }) {
            session.screenshots.append(s)
        }
    }

    public func insert(_ d: Decision) {
        let topicId = d.topic?.id ?? d.topicId
        d.id = run("INSERT INTO decisions(topic_id,timestamp,decision_text,source_speaker) VALUES(?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, topicId)
            bind(stmt, 2, d.timestamp)
            bind(stmt, 3, d.decisionText)
            bind(stmt, 4, d.sourceSpeaker)
        }
        d.topicId = topicId
        if let topic = d.topic, !topic.decisions.contains(where: { $0 === d }) {
            topic.decisions.append(d)
        }
    }

    public func insert(_ q: Question) {
        let topicId = q.topic?.id ?? q.topicId
        q.id = run("INSERT INTO questions(topic_id,timestamp,speaker,original_text,extracted_questions,question_type,confidence,status) VALUES(?,?,?,?,?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, topicId)
            bind(stmt, 2, q.timestamp)
            bind(stmt, 3, q.speaker)
            bind(stmt, 4, q.originalText)
            bind(stmt, 5, q.extractedQuestions)
            bind(stmt, 6, q.questionTypeRaw)
            sqlite3_bind_double(stmt, 7, Double(q.confidence))
            bind(stmt, 8, q.statusRaw)
        }
        q.topicId = topicId
        if let topic = q.topic, !topic.questions.contains(where: { $0 === q }) {
            topic.questions.append(q)
        }
    }

    public func insert(_ a: ActionItem) {
        let topicId = a.topic?.id ?? a.topicId
        a.id = run("INSERT INTO action_items(topic_id,timestamp,assigned_to,task,deadline,status,priority,source_speaker) VALUES(?,?,?,?,?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, topicId)
            bind(stmt, 2, a.timestamp)
            bind(stmt, 3, a.assignedTo)
            bind(stmt, 4, a.task)
            bind(stmt, 5, a.deadline)
            bind(stmt, 6, a.statusRaw)
            bind(stmt, 7, a.priority)
            bind(stmt, 8, a.sourceSpeaker)
        }
        a.topicId = topicId
        if let topic = a.topic, !topic.actionItems.contains(where: { $0 === a }) {
            topic.actionItems.append(a)
        }
    }

    public func update(_ s: MeetingSession) {
        run("UPDATE sessions SET start_time=?,end_time=?,status=?,title=?,summary=?,theme_id=?,meeting_type=?,template_id=?,quality_score=?,quality_issues=?,minutes_json=? WHERE id=?") { stmt in
            bind(stmt, 1, s.startTime)
            bind(stmt, 2, s.endTime)
            bind(stmt, 3, s.statusRaw)
            bind(stmt, 4, s.title)
            bind(stmt, 5, s.summary)
            if let themeId = s.themeId { sqlite3_bind_int64(stmt, 6, themeId) } else { sqlite3_bind_null(stmt, 6) }
            bind(stmt, 7, s.meetingType)
            bind(stmt, 8, s.templateId)
            if let q = s.qualityScore { sqlite3_bind_int64(stmt, 9, Int64(q)) } else { sqlite3_bind_null(stmt, 9) }
            bind(stmt, 10, s.qualityIssues)
            bind(stmt, 11, s.minutesJson)
            sqlite3_bind_int64(stmt, 12, s.id)
        }
    }

    public func update(_ a: ActionItem) {
        run("UPDATE action_items SET assigned_to=?,task=?,deadline=?,status=?,priority=?,source_speaker=? WHERE id=?") { stmt in
            bind(stmt, 1, a.assignedTo)
            bind(stmt, 2, a.task)
            bind(stmt, 3, a.deadline)
            bind(stmt, 4, a.statusRaw)
            bind(stmt, 5, a.priority)
            bind(stmt, 6, a.sourceSpeaker)
            sqlite3_bind_int64(stmt, 7, a.id)
        }
    }

    public func update(_ d: Decision) {
        run("UPDATE decisions SET decision_text=?,source_speaker=? WHERE id=?") { stmt in
            bind(stmt, 1, d.decisionText)
            bind(stmt, 2, d.sourceSpeaker)
            sqlite3_bind_int64(stmt, 3, d.id)
        }
    }

    public func update(_ t: Topic) {
        run("UPDATE topics SET title=?,start_time=?,end_time=?,order_index=?,summary=? WHERE id=?") { stmt in
            bind(stmt, 1, t.title)
            bind(stmt, 2, t.startTime)
            bind(stmt, 3, t.endTime)
            sqlite3_bind_int64(stmt, 4, Int64(t.orderIndex))
            bind(stmt, 5, t.summary)
            sqlite3_bind_int64(stmt, 6, t.id)
        }
    }

    public func update(_ t: Transcript) {
        run("UPDATE transcripts SET timestamp=?,speaker=?,text=?,is_final=?,confidence=? WHERE id=?") { stmt in
            bind(stmt, 1, t.timestamp)
            bind(stmt, 2, t.speaker)
            bind(stmt, 3, t.text)
            sqlite3_bind_int(stmt, 4, t.isFinal ? 1 : 0)
            sqlite3_bind_double(stmt, 5, Double(t.confidence))
            sqlite3_bind_int64(stmt, 6, t.id)
        }
    }

    public func update(_ s: Screenshot) {
        run("UPDATE screenshots SET timestamp=?,file_path=?,image_hash=?,ai_summary=?,ocr_text=?,content_type=?,key_entities=?,key_numbers=?,meeting_relevance=?,sensitivity_level=?,analysis_status=?,active_speaker_name=?,key_dates=?,slide_decisions=?,slide_action_items=?,chart_type=?,chart_insight=? WHERE id=?") { stmt in
            bind(stmt, 1, s.timestamp)
            bind(stmt, 2, s.filePath)
            bind(stmt, 3, s.imageHash)
            bind(stmt, 4, s.aiSummary)
            bind(stmt, 5, s.ocrText)
            bind(stmt, 6, s.contentType)
            bind(stmt, 7, s.keyEntities)
            bind(stmt, 8, s.keyNumbers)
            bind(stmt, 9, s.meetingRelevance)
            bind(stmt, 10, s.sensitivityLevel)
            bind(stmt, 11, s.analysisStatus)
            bind(stmt, 12, s.activeSpeakerName)
            bind(stmt, 13, s.keyDates)
            bind(stmt, 14, s.slideDecisions)
            bind(stmt, 15, s.slideActionItems)
            bind(stmt, 16, s.chartType)
            bind(stmt, 17, s.chartInsight)
            sqlite3_bind_int64(stmt, 18, s.id)
        }
    }

    private func mapSession(_ stmt: OpaquePointer?) -> MeetingSession {
        let s = MeetingSession(startTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                               title: text(stmt, 4))
        s.id = sqlite3_column_int64(stmt, 0)
        s.endTime = date(stmt, 2)
        s.statusRaw = text(stmt, 3) ?? "idle"
        s.summary = text(stmt, 5)
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL { s.themeId = sqlite3_column_int64(stmt, 6) }
        s.meetingType = text(stmt, 7)
        s.templateId = text(stmt, 8)
        if sqlite3_column_type(stmt, 9) != SQLITE_NULL { s.qualityScore = Int(sqlite3_column_int64(stmt, 9)) }
        s.qualityIssues = text(stmt, 10)
        s.minutesJson = text(stmt, 11)
        return s
    }

    private func mapTopic(_ stmt: OpaquePointer?) -> Topic {
        let t = Topic(title: text(stmt, 2) ?? "",
                      startTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                      orderIndex: Int(sqlite3_column_int64(stmt, 5)))
        t.id = sqlite3_column_int64(stmt, 0)
        t.sessionId = sqlite3_column_int64(stmt, 1)
        t.endTime = date(stmt, 4)
        t.summary = text(stmt, 6)
        return t
    }

    private func mapTranscript(_ stmt: OpaquePointer?) -> Transcript {
        let t = Transcript(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                           speaker: text(stmt, 3),
                           text: text(stmt, 4) ?? "",
                           isFinal: sqlite3_column_int(stmt, 5) != 0,
                           confidence: Float(sqlite3_column_double(stmt, 6)))
        t.id = sqlite3_column_int64(stmt, 0)
        t.topicId = sqlite3_column_int64(stmt, 1)
        return t
    }

    private func mapScreenshot(_ stmt: OpaquePointer?) -> Screenshot {
        let s = Screenshot(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                           filePath: text(stmt, 3) ?? "",
                           imageHash: text(stmt, 4))
        s.id = sqlite3_column_int64(stmt, 0)
        s.sessionId = sqlite3_column_int64(stmt, 1)
        s.aiSummary = text(stmt, 5)
        s.ocrText = text(stmt, 6)
        s.contentType = text(stmt, 7)
        s.keyEntities = text(stmt, 8)
        s.keyNumbers = text(stmt, 9)
        s.meetingRelevance = text(stmt, 10)
        s.sensitivityLevel = text(stmt, 11)
        s.analysisStatus = text(stmt, 12)
        s.activeSpeakerName = text(stmt, 13)
        s.keyDates = text(stmt, 14)
        s.slideDecisions = text(stmt, 15)
        s.slideActionItems = text(stmt, 16)
        s.chartType = text(stmt, 17)
        s.chartInsight = text(stmt, 18)
        return s
    }

    public func endMonitoringSessions() {
        run("UPDATE sessions SET end_time=?, status=? WHERE status=?") { stmt in
            bind(stmt, 1, Date())
            bind(stmt, 2, SessionStatus.ended.rawValue)
            bind(stmt, 3, SessionStatus.monitoring.rawValue)
        }
    }

    private static let sessionColumns = "id,start_time,end_time,status,title,summary,theme_id,meeting_type,template_id,quality_score,quality_issues,minutes_json"

    public func fetchSessions() -> [MeetingSession] {
        query("SELECT \(Self.sessionColumns) FROM sessions ORDER BY start_time DESC", map: mapSession)
    }

    public func fetchTopics(sessionId: Int64) -> [Topic] {
        query("SELECT id,session_id,title,start_time,end_time,order_index,summary FROM topics WHERE session_id=? ORDER BY order_index", bind: { sqlite3_bind_int64($0, 1, sessionId) }, map: mapTopic)
    }

    public func fetchTranscripts(topicId: Int64) -> [Transcript] {
        query("SELECT id,topic_id,timestamp,speaker,text,is_final,confidence FROM transcripts WHERE topic_id=? ORDER BY timestamp", bind: { sqlite3_bind_int64($0, 1, topicId) }, map: mapTranscript)
    }

    public func fetchScreenshots(sessionId: Int64) -> [Screenshot] {
        query("SELECT id,session_id,timestamp,file_path,image_hash,ai_summary,ocr_text,content_type,key_entities,key_numbers,meeting_relevance,sensitivity_level,analysis_status,active_speaker_name,key_dates,slide_decisions,slide_action_items,chart_type,chart_insight FROM screenshots WHERE session_id=? ORDER BY timestamp", bind: { sqlite3_bind_int64($0, 1, sessionId) }, map: mapScreenshot)
    }

    public func fetchDecisions(topicId: Int64) -> [Decision] {
        query("SELECT id,topic_id,timestamp,decision_text,source_speaker FROM decisions WHERE topic_id=? ORDER BY timestamp", bind: { sqlite3_bind_int64($0, 1, topicId) }) { stmt in
            let d = Decision(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                             decisionText: text(stmt, 3) ?? "")
            d.id = sqlite3_column_int64(stmt, 0)
            d.topicId = sqlite3_column_int64(stmt, 1)
            d.sourceSpeaker = text(stmt, 4)
            return d
        }
    }

    public func fetchActionItems(topicId: Int64) -> [ActionItem] {
        query("SELECT id,topic_id,timestamp,assigned_to,task,deadline,status,priority,source_speaker FROM action_items WHERE topic_id=? ORDER BY timestamp", bind: { sqlite3_bind_int64($0, 1, topicId) }) { stmt in
            let a = ActionItem(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                               assignedTo: text(stmt, 3) ?? "",
                               task: text(stmt, 4) ?? "",
                               deadline: text(stmt, 5))
            a.id = sqlite3_column_int64(stmt, 0)
            a.topicId = sqlite3_column_int64(stmt, 1)
            a.statusRaw = text(stmt, 6) ?? ActionItemStatus.notStarted.rawValue
            a.priority = text(stmt, 7)
            a.sourceSpeaker = text(stmt, 8)
            return a
        }
    }

    public func fetchQuestions(topicId: Int64) -> [Question] {
        query("SELECT id,topic_id,timestamp,speaker,original_text,extracted_questions,question_type,confidence,status FROM questions WHERE topic_id=? ORDER BY timestamp", bind: { sqlite3_bind_int64($0, 1, topicId) }) { stmt in
            let q = Question(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                             speaker: text(stmt, 3),
                             originalText: text(stmt, 4) ?? "")
            q.id = sqlite3_column_int64(stmt, 0)
            q.topicId = sqlite3_column_int64(stmt, 1)
            q.extractedQuestions = text(stmt, 5)
            q.questionTypeRaw = text(stmt, 6) ?? QuestionType.direct.rawValue
            q.confidence = Float(sqlite3_column_double(stmt, 7))
            q.statusRaw = text(stmt, 8) ?? QuestionStatus.pending.rawValue
            return q
        }
    }

    public func fetchTranscriptCounts() -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        let rows = query("SELECT t2.session_id, COUNT(*) FROM transcripts t1 JOIN topics t2 ON t1.topic_id=t2.id GROUP BY t2.session_id") { stmt -> (Int64, Int) in
            (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int64(stmt, 1)))
        }
        for (k, v) in rows { out[k] = v }
        return out
    }

    public func fetchDetail(sessionId: Int64) -> MeetingSession? {
        guard let session = query("SELECT \(Self.sessionColumns) FROM sessions WHERE id=?", bind: { sqlite3_bind_int64($0, 1, sessionId) }, map: mapSession).first else {
            return nil
        }
        session.topics = fetchTopics(sessionId: sessionId)
        session.screenshots = fetchScreenshots(sessionId: sessionId)
        for topic in session.topics {
            topic.session = session
            topic.transcripts = fetchTranscripts(topicId: topic.id)
            topic.decisions = fetchDecisions(topicId: topic.id)
            topic.questions = fetchQuestions(topicId: topic.id)
            topic.actionItems = fetchActionItems(topicId: topic.id)
            for tr in topic.transcripts { tr.topic = topic }
            for d in topic.decisions { d.topic = topic }
            for q in topic.questions { q.topic = topic }
            for a in topic.actionItems { a.topic = topic }
        }
        for s in session.screenshots { s.session = session }
        return session
    }

    public func deleteSession(id: Int64) -> [String] {
        let paths = fetchScreenshots(sessionId: id).map(\.filePath)
        run("DELETE FROM sessions WHERE id=?") { sqlite3_bind_int64($0, 1, id) }
        return paths
    }

    public func countSessions() -> Int {
        query("SELECT COUNT(*) FROM sessions") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func countTranscripts() -> Int {
        query("SELECT COUNT(*) FROM transcripts") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func countScreenshots() -> Int {
        query("SELECT COUNT(*) FROM screenshots") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func totalMeetingSeconds() -> Int {
        query("SELECT COALESCE(SUM(end_time - start_time), 0) FROM sessions WHERE end_time IS NOT NULL") { Int(sqlite3_column_double($0, 0)) }.first ?? 0
    }

    public func deleteAllMeetingData() {
        exec("DELETE FROM transcripts")
        exec("DELETE FROM decisions")
        exec("DELETE FROM questions")
        exec("DELETE FROM action_items")
        exec("DELETE FROM topics")
        exec("DELETE FROM screenshots")
        exec("DELETE FROM sessions")
    }

    public func deleteTranscriptHistory() {
        exec("DELETE FROM transcripts")
        exec("DELETE FROM decisions")
        exec("DELETE FROM questions")
        exec("DELETE FROM action_items")
        exec("DELETE FROM topics")
        exec("DELETE FROM sessions")
    }

    public func allScreenshotPaths() -> [String] {
        query("SELECT file_path FROM screenshots") { text($0, 0) ?? "" }
    }

    public func deleteAllScreenshots() {
        exec("DELETE FROM screenshots")
    }

    public func latestMonitoringOrRecentSession() -> MeetingSession? {
        if let monitoring = query("SELECT \(Self.sessionColumns) FROM sessions WHERE status='monitoring' ORDER BY start_time DESC LIMIT 1", map: mapSession).first {
            return fetchDetail(sessionId: monitoring.id)
        }
        guard let latest = query("SELECT \(Self.sessionColumns) FROM sessions ORDER BY start_time DESC LIMIT 1", map: mapSession).first else {
            return nil
        }
        return fetchDetail(sessionId: latest.id)
    }

    // MARK: - Themes

    private func mapTheme(_ stmt: OpaquePointer?) -> MeetingTheme {
        let t = MeetingTheme(name: text(stmt, 1) ?? "")
        t.id = sqlite3_column_int64(stmt, 0)
        t.keywordsJoined = text(stmt, 2) ?? ""
        t.createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        t.updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        t.archived = sqlite3_column_int(stmt, 5) != 0
        return t
    }

    public func insert(_ t: MeetingTheme) {
        t.id = run("INSERT INTO themes(name,keywords,created_at,updated_at,archived) VALUES(?,?,?,?,?)") { stmt in
            bind(stmt, 1, t.name)
            bind(stmt, 2, t.keywordsJoined)
            bind(stmt, 3, t.createdAt)
            bind(stmt, 4, t.updatedAt)
            sqlite3_bind_int(stmt, 5, t.archived ? 1 : 0)
        }
    }

    public func update(_ t: MeetingTheme) {
        t.updatedAt = Date()
        run("UPDATE themes SET name=?,keywords=?,updated_at=?,archived=? WHERE id=?") { stmt in
            bind(stmt, 1, t.name)
            bind(stmt, 2, t.keywordsJoined)
            bind(stmt, 3, t.updatedAt)
            sqlite3_bind_int(stmt, 4, t.archived ? 1 : 0)
            sqlite3_bind_int64(stmt, 5, t.id)
        }
    }

    public func fetchThemes(includeArchived: Bool = true) -> [MeetingTheme] {
        if includeArchived {
            return query("SELECT id,name,keywords,created_at,updated_at,archived FROM themes ORDER BY updated_at DESC", map: mapTheme)
        }
        return query("SELECT id,name,keywords,created_at,updated_at,archived FROM themes WHERE archived=0 ORDER BY updated_at DESC", map: mapTheme)
    }

    public func fetchTheme(id: Int64) -> MeetingTheme? {
        query("SELECT id,name,keywords,created_at,updated_at,archived FROM themes WHERE id=?", bind: { sqlite3_bind_int64($0, 1, id) }, map: mapTheme).first
    }

    public func fetchSessions(themeId: Int64) -> [MeetingSession] {
        query("SELECT \(Self.sessionColumns) FROM sessions WHERE theme_id=? ORDER BY start_time DESC", bind: { sqlite3_bind_int64($0, 1, themeId) }, map: mapSession)
    }

    public func assignSessionTheme(sessionId: Int64, themeId: Int64?) {
        run("UPDATE sessions SET theme_id=? WHERE id=?") { stmt in
            if let themeId { sqlite3_bind_int64(stmt, 1, themeId) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int64(stmt, 2, sessionId)
        }
    }

    public func mergeThemes(from sourceId: Int64, into targetId: Int64) {
        run("UPDATE sessions SET theme_id=? WHERE theme_id=?") { stmt in
            sqlite3_bind_int64(stmt, 1, targetId)
            sqlite3_bind_int64(stmt, 2, sourceId)
        }
        run("DELETE FROM themes WHERE id=?") { sqlite3_bind_int64($0, 1, sourceId) }
    }

    public func deleteTheme(id: Int64) {
        run("DELETE FROM themes WHERE id=?") { sqlite3_bind_int64($0, 1, id) }
    }

    public func updateActionItemStatus(id: Int64, status: ActionItemStatus) {
        run("UPDATE action_items SET status=? WHERE id=?") { stmt in
            bind(stmt, 1, status.rawValue)
            sqlite3_bind_int64(stmt, 2, id)
        }
    }
}
