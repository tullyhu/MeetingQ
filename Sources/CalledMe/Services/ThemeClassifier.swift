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

public enum ThemeClassifier {
    private static let attachThreshold = 0.45
    private static let candidateThreshold = 0.15
    private static let ninetyDays: TimeInterval = 90 * 24 * 3600

    private struct SessionSignature {
        let title: String
        let text: String
        let keywords: [String]
    }

    private static func signature(for session: MeetingSession) -> SessionSignature {
        let topicTitles = session.topics.map(\.title).joined(separator: " ")
        let summary = session.summary ?? ""
        let decisions = session.topics.flatMap(\.decisions).map(\.decisionText).joined(separator: " ")
        let text = [session.title ?? "", topicTitles, summary, decisions].joined(separator: " ")
        return SessionSignature(title: session.title ?? "", text: text, keywords: topKeywords(text))
    }

    public static func classify(session: MeetingSession, llm: LlmService) async -> Int64? {
        let store = DataStore.shared
        let themes = store.fetchThemes(includeArchived: false)
        let sig = signature(for: session)
        guard !sig.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var candidates: [(theme: MeetingTheme, score: Double)] = themes.map { theme in
            (theme, similarity(sig.text, theme.name + " " + theme.keywords.joined(separator: " ")))
        }
        for i in candidates.indices {
            if let latest = store.fetchSessions(themeId: candidates[i].theme.id).first,
               session.startTime.timeIntervalSince(latest.startTime) > ninetyDays {
                candidates[i].score *= 0.5
            }
        }
        candidates = candidates.filter { $0.score > candidateThreshold }
            .sorted { $0.score > $1.score }
        let topCandidates = Array(candidates.prefix(5))

        if let llmDecision = await llmClassify(signature: sig, candidates: topCandidates, llm: llm) {
            return apply(llmDecision, signature: sig, store: store)
        }

        if let best = candidates.first, best.score > attachThreshold {
            mergeKeywords(into: best.theme, from: sig.keywords, store: store)
            return best.theme.id
        }
        return createTheme(from: sig, store: store).id
    }

    private struct LlmDecision {
        let action: String
        let themeId: Int64?
        let newName: String?
        let keywords: [String]
    }

    private static func llmClassify(signature sig: SessionSignature,
                                      candidates: [(theme: MeetingTheme, score: Double)],
                                      llm: LlmService) async -> LlmDecision? {
        var candidateDesc = ""
        for (i, c) in candidates.enumerated() {
            candidateDesc += "\(i + 1). id=\(c.theme.id) | \(c.theme.name) | keywords: \(c.theme.keywords.joined(separator: ", "))\n"
        }

        let prompt: String
        if AppLanguage.current.isEnglish {
            prompt = """
            Decide whether the meeting below belongs to an existing theme (an ongoing project/activity spanning multiple meetings) or needs a new theme.

            Meeting:
            Title: \(sig.title)
            Content signature: \(String(sig.text.prefix(800)))

            Candidate themes:
            \(candidateDesc.isEmpty ? "(none)" : candidateDesc)
            Rules: attach only when the meeting clearly continues the same project/activity; otherwise create a new theme. New theme names must follow "[project/product] + [stage/activity]", e.g. "Product Launch Prep". Meetings over 90 days apart usually need a new theme.
            Return JSON only: {"action":"attach" or "create","theme_id":number or null,"new_theme_name":"name when creating, else null","keywords":["3-5 keywords"]}
            """
        } else {
            prompt = """
            判断下面这场会议属于某个已有主题（跨多次会议的同一项目/活动），还是需要新建主题。

            会议：
            标题：\(sig.title)
            内容签名：\(String(sig.text.prefix(800)))

            候选主题：
            \(candidateDesc.isEmpty ? "（无）" : candidateDesc)
            规则：仅当会议明显延续同一项目/活动时归入已有主题，否则新建。新主题命名遵循「项目/产品名 + 阶段/活动类型」，如"产品上线筹备"。相隔超过90天的会议通常应新建主题。
            只返回JSON：{"action":"attach" 或 "create","theme_id":数字或null,"new_theme_name":"新建时的名称，否则null","keywords":["3-5个关键词"]}
            """
        }

        guard let response = try? await llm.analyze(prompt) else { return nil }
        var text = response
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), end > start {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = root["action"] as? String else { return nil }

        var themeId: Int64?
        if let n = root["theme_id"] as? Int { themeId = Int64(n) }
        else if let n = root["theme_id"] as? Int64 { themeId = n }
        else if let s = root["theme_id"] as? String { themeId = Int64(s) }

        return LlmDecision(action: action,
                           themeId: themeId,
                           newName: root["new_theme_name"] as? String,
                           keywords: (root["keywords"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }

    private static func apply(_ decision: LlmDecision, signature sig: SessionSignature, store: DataStore) -> Int64 {
        if decision.action == "attach", let themeId = decision.themeId, let theme = store.fetchTheme(id: themeId) {
            mergeKeywords(into: theme, from: sig.keywords + decision.keywords, store: store)
            return theme.id
        }
        let name = decision.newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return createTheme(from: sig, name: (name?.isEmpty == false ? name : nil), extraKeywords: decision.keywords, store: store).id
    }

    private static func createTheme(from sig: SessionSignature, name: String? = nil, extraKeywords: [String] = [], store: DataStore) -> MeetingTheme {
        let themeName: String
        if let name, !name.isEmpty, name.count <= 30 {
            themeName = name
        } else if !sig.keywords.isEmpty {
            themeName = sig.keywords.prefix(2).joined(separator: " ")
        } else {
            themeName = sig.title
        }
        let theme = MeetingTheme(name: themeName, keywords: Array((sig.keywords + extraKeywords).uniqued().prefix(8)))
        store.insert(theme)
        return theme
    }

    private static func mergeKeywords(into theme: MeetingTheme, from newKeywords: [String], store: DataStore) {
        let merged = Array((theme.keywords + newKeywords).uniqued().prefix(10))
        if merged != theme.keywords {
            theme.keywords = merged
            store.update(theme)
        }
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = MinutesQualityAssessor.bigrams(a)
        let tb = MinutesQualityAssessor.bigrams(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private static func topKeywords(_ text: String) -> [String] {
        let stop: Set<String> = ["我们", "你们", "他们", "这个", "那个", "就是", "可以", "什么", "怎么", "现在", "然后", "因为", "所以", "但是", "如果", "没有", "the", "and", "for", "that", "this", "with", "have", "will"]
        var counts: [String: Int] = [:]
        let chars = Array(text.lowercased().filter { !$0.isPunctuation && !$0.isWhitespace })
        guard chars.count >= 2 else { return [] }
        var i = 0
        while i < chars.count - 1 {
            let len = min(4, chars.count - i)
            if len >= 2 {
                for l in [4, 3, 2] where l <= len {
                    let word = String(chars[i..<(i + l)])
                    if !stop.contains(word) {
                        counts[word, default: 0] += 1
                    }
                }
            }
            i += 1
        }
        return counts.filter { $0.value >= 2 && $0.key.count >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map(\.key)
    }
}

public enum CrossMeetingActionTracker {
    public struct TrackedAction: Sendable {
        public var representative: ActionItem
        public var occurrences: [ActionItem]
        public var mentionCount: Int
    }

    public static func group(_ items: [ActionItem]) -> [TrackedAction] {
        var groups: [[ActionItem]] = []
        for item in items {
            var placed = false
            for gi in groups.indices {
                if let rep = groups[gi].first,
                   ThemeClassifier.similarity(rep.task, item.task) > 0.6 {
                    groups[gi].append(item)
                    placed = true
                    break
                }
            }
            if !placed { groups.append([item]) }
        }
        return groups.map { group in
            let sorted = group.sorted { $0.timestamp < $1.timestamp }
            return TrackedAction(representative: sorted.last ?? group[0],
                                 occurrences: sorted,
                                 mentionCount: group.count)
        }.sorted { $0.representative.timestamp > $1.representative.timestamp }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
