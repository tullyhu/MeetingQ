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

public final class NameDetectionServiceImpl: NameDetectionService {
    private let llm: LlmService
    private let lock = NSLock()
    private var nameRegex: NSRegularExpression?
    private var loadedNames: [String] = []
    private var userRole: String = ""

    private static let questionParticles = ["吗", "呢", "么", "嘛", "啊"]

    private static let interrogativeWords =
        ["什么", "怎么", "为什么", "哪里", "哪个", "哪些", "谁", "多少", "几", "如何", "是否"]

    private static let directedPhrases =
        ["你觉得", "你认为", "你说", "你来", "你有", "你能", "请你", "问你", "想问你",
         "你的意见", "你的看法", "你怎么看", "你们觉得", "你们认为"]

    public init(llm: LlmService) {
        self.llm = llm
        reloadNames()
    }

    public func reloadNames() {
        var names: [String] = []

        func split(_ value: String?) -> [String] {
            (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("：") && !$0.contains(":") }
        }

        names.append(contentsOf: split(KeychainStorage.load(StoreKeys.userName)))
        names.append(contentsOf: split(KeychainStorage.load(StoreKeys.userNicknames)))
        names.append(contentsOf: split(KeychainStorage.load(StoreKeys.userAsrVariants)))

        var seen = Set<String>()
        let deduped = names.filter { seen.insert($0.lowercased()).inserted }
        let role = (KeychainStorage.load(StoreKeys.userRole) ?? "").trimmingCharacters(in: .whitespaces)

        lock.lock()
        loadedNames = deduped
        userRole = role
        if !deduped.isEmpty {
            let pattern = deduped.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            nameRegex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } else {
            nameRegex = nil
        }
        lock.unlock()
    }

    public func detect(_ text: String) -> DetectionResult {
        let layer0 = runLayer0(text)
        if layer0.isDetected { return layer0 }
        return runLayer1(text)
    }

    public func detectAsync(_ text: String) async -> DetectionResult {
        let result = detect(text)
        if result.isDetected {
            return await runLayer2(text, preliminary: result)
        }
        return result
    }

    private func runLayer0(_ text: String) -> DetectionResult {
        lock.lock()
        let regex = nameRegex
        let names = loadedNames
        lock.unlock()

        if let regex {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text) {
                let matched = String(text[matchRange])
                var result = DetectionResult()
                result.isDetected = true
                result.confidence = 0.85
                result.matchedName = matched
                result.originalText = text
                result.detectionLayer = 0
                return result
            }
        }

        for name in names where name.count >= 2 {
            if let pinyinMatch = PinyinHelper.findPinyinMatch(name: name, in: text), pinyinMatch != name {
                autoAddAsrVariant(pinyinMatch)
                var result = DetectionResult()
                result.isDetected = true
                result.confidence = 0.75
                result.matchedName = pinyinMatch
                result.originalText = text
                result.detectionLayer = 0
                return result
            }
        }

        var result = DetectionResult()
        result.originalText = text
        result.detectionLayer = 0
        return result
    }

    private func autoAddAsrVariant(_ variant: String) {
        lock.lock()
        let known = loadedNames.contains { $0.caseInsensitiveCompare(variant) == .orderedSame }
        lock.unlock()
        guard !known else { return }

        let existing = KeychainStorage.load(StoreKeys.userAsrVariants) ?? ""
        let updated = existing.isEmpty ? variant : existing + "," + variant
        KeychainStorage.save(StoreKeys.userAsrVariants, value: updated)
        reloadNames()
    }

    private func runLayer1(_ text: String) -> DetectionResult {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "，。！ "))
        let endsWithQuestion = Self.questionParticles.contains { trimmed.hasSuffix($0) }
        let hasInterrogative = Self.interrogativeWords.contains { text.contains($0) }
        let hasDirectedPhrase = Self.directedPhrases.contains { text.contains($0) }

        if hasDirectedPhrase || (endsWithQuestion && hasInterrogative) {
            var result = DetectionResult()
            result.isDetected = true
            result.confidence = hasDirectedPhrase ? 0.7 : 0.5
            result.originalText = text
            result.detectionLayer = 1
            return result
        }

        var result = DetectionResult()
        result.originalText = text
        result.detectionLayer = 1
        return result
    }

    private func runLayer2(_ text: String, preliminary: DetectionResult) async -> DetectionResult {
        lock.lock()
        let names = loadedNames
        let role = userRole
        lock.unlock()

        let namesHint = names.isEmpty
            ? tr("（用户未配置名字）", "(user name not configured)")
            : tr("用户姓名/昵称：", "User name/nicknames: ") + names.joined(separator: tr("、", ", "))
        let roleHint = role.isEmpty ? "" : tr("\n用户角色：\(role)（可据此判断该角色相关的职责性问题是否指向该用户）",
                                              "\nUser role: \(role) (use this to judge whether role-related responsibility questions are directed at this user)")

        let prompt: String
        if AppLanguage.current.isEnglish {
            prompt = """
            \(namesHint)\(roleHint)

            Someone said this in the meeting: "\(text)"

            Determine whether this sentence is directed at the user above:
            - Criteria: the sentence contains the user's name or nickname (including possible ASR misrecognitions), or there is clear context addressing this user, or the question clearly relates to the user's role and the context implies it targets them.
            - Note: generic uses of "you" without the user's name/nickname usually address someone else — return directed=false.

            Return JSON only, format: {"directed":true,"questions":["the specific questions"]}
            If not directed at the user: {"directed":false,"questions":[]}
            """
        } else {
            prompt = """
            \(namesHint)\(roleHint)

            会议中说了这句话："\(text)"

            请判断这句话是否直接针对上述用户本人：
            - 判断依据：句中出现用户的姓名或昵称（含语音识别可能造成的同音字误识别），或有明确点名该用户的上下文，或问题明显与其角色职责相关且上下文隐含指向该用户。
            - 注意：句中出现"你"、"你来"、"你觉得"等泛称，但未出现用户姓名/昵称时，通常是在对其他人说话，应返回 directed=false。

            只返回JSON，格式：{"directed":true,"questions":["具体问题"]}
            若不是针对用户：{"directed":false,"questions":[]}
            """
        }

        do {
            let response = try await llm.analyze(prompt)
            if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return preliminary }

            guard let jsonStart = response.firstIndex(of: "{"),
                  let jsonEnd = response.lastIndex(of: "}"), jsonEnd > jsonStart else { return preliminary }
            let json = String(response[jsonStart...jsonEnd])

            guard let data = json.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return preliminary }

            var result = preliminary
            guard (root["directed"] as? Bool) == true else {
                result.isDetected = false
                return result
            }

            var questions: [String] = []
            if let arr = root["questions"] as? [Any] {
                questions = arr.compactMap { $0 as? String }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }

            result.extractedQuestions = questions.isEmpty ? [text] : questions
            result.detectionLayer = 2
            result.confidence = 0.95

            return result
        } catch {
            return preliminary
        }
    }
}
