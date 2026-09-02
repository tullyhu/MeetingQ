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

public final class VisionServiceImpl: VisionService {
    private let llm: LlmService
    private let localOcr: (any LocalOcrService)?
    private let isOcrFallbackEnabled: @Sendable () -> Bool
    private let analysisEngine: @Sendable () -> String
    private let gate = Gate()

    private static let maxRetries = 2
    private static let maxConsecutiveFails = 3
    private var consecutiveFails = 0

    public init(llm: LlmService,
                localOcr: (any LocalOcrService)? = nil,
                isOcrFallbackEnabled: (@Sendable () -> Bool)? = nil,
                analysisEngine: (@Sendable () -> String)? = nil) {
        self.llm = llm
        self.localOcr = localOcr
        self.isOcrFallbackEnabled = isOcrFallbackEnabled ?? { true }
        self.analysisEngine = analysisEngine ?? { "llm" }
    }

    public func analyzeScreenshot(imagePath: String, currentTopic: String?, surroundingTranscripts: [String]) async throws -> VisionAnalysisResult {
        if analysisEngine() == "local_ocr" {
            return await localOcrResult(imagePath: imagePath)
        }
        if consecutiveFails >= Self.maxConsecutiveFails {
            return await degradedResult(tr("分析暂不可用（连续失败）", "Analysis temporarily unavailable (repeated failures)"), imagePath: imagePath)
        }

        await gate.wait()
        defer { Task { await gate.release() } }

        let imageData: Data
        do {
            imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        } catch {
            return Self.fallbackResult(tr("图片读取失败", "Failed to read image"))
        }

        let base64 = imageData.base64EncodedString()
        let transcripts = surroundingTranscripts.isEmpty
            ? tr("（无）", "(none)")
            : surroundingTranscripts.suffix(6).joined(separator: "\n")

        let topicText = currentTopic ?? tr("（未检测）", "(not detected)")
        let userMessage: String
        if AppLanguage.current.isEnglish {
            userMessage = "[Meeting Context]\nCurrent topic: " + topicText + "\n\n[Transcript around the screenshot time]\n" + transcripts + "\n\n[Task]\nAnalyze the screenshot, focusing on:\n1. What is shown on screen (document/slide/chart/whiteboard/code/chat window/other)\n2. Key data, conclusions, or information\n3. Relevance to the current meeting discussion\n4. Readable text in the image (OCR)\n5. The name of the person currently speaking in the video-conference UI (usually shown at the top/bottom/corner, e.g. \"Alex is speaking\")\n6. If it is a slide/document: extract key dates (YYYY-MM-DD with context), decisions written on it, action items (with owner/deadline if shown)\n7. If it is a chart: identify the chart type and the single most important insight (trend or comparison)\n\n[Important] Output only the following JSON format, with field names strictly in lowercase English with underscores:\n{\n  \"ai_summary\": \"2-4 sentences describing the image content and its relation to the meeting\",\n  \"content_type\": \"slide/chart/document/whiteboard/code/chat/browser/other\",\n  \"key_entities\": [\"keyword1\", \"keyword2\"],\n  \"key_numbers\": [\"12%\", \"500k\"],\n  \"key_dates\": [\"2026-09-10 launch\", \"2026-09-05 UAT done\"],\n  \"slide_decisions\": [\"decision text written on the slide\"],\n  \"slide_action_items\": [\"task — owner — deadline\"],\n  \"chart_type\": \"bar/line/pie/table or null\",\n  \"chart_insight\": \"one sentence on the key trend/comparison or null\",\n  \"ocr_text\": \"readable text in the image (key parts)\",\n  \"meeting_relevance\": \"high/medium/low\",\n  \"sensitivity_level\": \"low/medium/high\",\n  \"active_speaker_name\": \"name of the current speaker (if visible), otherwise null\"\n}\nUse empty arrays when nothing applies. Output JSON only, no explanations."
        } else {
            userMessage = "【会议背景】\n当前议题: " + topicText + "\n\n【截图时间点前后的转写】\n" + transcripts + "\n\n【任务】\n分析截图内容,重点关注:\n1. 屏幕上展示的是什么(文档/幻灯片/数据图表/白板/代码/聊天窗口/其他)\n2. 关键数据、结论或信息\n3. 与当前会议讨论的关联性\n4. 图中可读文字(OCR)\n5. 视频会议UI中正在发言的人的名字(通常在屏幕顶部/底部/角落显示当前讲话人名称，如\"张三 正在发言\"、\"李四 (发言中)\"等)\n6. 如果是幻灯片/文档:提取关键日期(YYYY-MM-DD并注明含义)、页面上写明的决策、行动项(含负责人/截止时间如有)\n7. 如果是图表:识别图表类型，并用一句话概括最重要的趋势或对比结论\n\n【重要】仅输出以下 JSON 格式,字段名严格使用英文小写+下划线:\n{\n  \"ai_summary\": \"2~4句描述图中内容和会议关联\",\n  \"content_type\": \"slide/chart/document/whiteboard/code/chat/browser/other\",\n  \"key_entities\": [\"关键词1\", \"关键词2\"],\n  \"key_numbers\": [\"12%\", \"50万\"],\n  \"key_dates\": [\"2026-09-10 上线\", \"2026-09-05 完成UAT\"],\n  \"slide_decisions\": [\"页面上写明的决策原文\"],\n  \"slide_action_items\": [\"任务 — 负责人 — 截止时间\"],\n  \"chart_type\": \"bar/line/pie/table 或 null\",\n  \"chart_insight\": \"一句话概括关键趋势/对比，没有则 null\",\n  \"ocr_text\": \"图中可读文字(关键部分)\",\n  \"meeting_relevance\": \"high/medium/low\",\n  \"sensitivity_level\": \"low/medium/high\",\n  \"active_speaker_name\": \"当前发言人的名字(如能看到)，否则填null\"\n}\n没有内容的数组字段填空数组。只输出 JSON,不要解释,不要使用中文字段名。"
        }

        let systemPrompt = tr("你是会议视觉内容分析助手。请分析这张会议截图并生成结构化描述。",
                              "You are a meeting visual-content analysis assistant. Analyze this meeting screenshot and produce a structured description.")

        var response: String?
        var lastErrorHint = tr("分析失败", "Analysis failed")
        for _ in 0...Self.maxRetries {
            do {
                response = try await llm.analyzeImage(systemPrompt: systemPrompt, userMessage: userMessage, imageBase64: base64, modelOverride: nil)
                break
            } catch is CancellationError {
                lastErrorHint = tr("分析超时", "Analysis timed out")
            } catch {
                lastErrorHint = tr("分析失败: \(error.localizedDescription)", "Analysis failed: \(error.localizedDescription)")
            }
        }

        guard let response else {
            consecutiveFails += 1
            return await degradedResult(lastErrorHint, imagePath: imagePath)
        }

        do {
            let result = try Self.parseResult(response)
            consecutiveFails = 0

            if result.aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return await degradedResult(tr("模型未返回有效分析内容", "Model returned no valid analysis"), imagePath: imagePath)
            }

            return result
        } catch {
            consecutiveFails += 1
            return await degradedResult(tr("响应解析失败", "Failed to parse response"), imagePath: imagePath)
        }
    }

    public func testConnection() async throws -> Bool {
        do {
            let testImage = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYI4Q/SFhSRFJiMkVic4EzRjRzU5I0nB/9oADAMBAAIRAxEAPwDn+/+f/9k="
            let result = try await llm.analyzeImage(
                systemPrompt: "You are a helpful assistant.",
                userMessage: "Reply with exactly: ok",
                imageBase64: testImage,
                modelOverride: nil)
            return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("ok")
        } catch {
            return false
        }
    }

    private static func parseResult(_ response: String) throws -> VisionAnalysisResult {
        var json = response
        if let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), end > start {
            json = String(response[start...end])
        }

        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurableLlmService.error(tr("Vision 响应解析失败", "Failed to parse Vision response"))
        }

        var result = VisionAnalysisResult()
        result.aiSummary = getStringProperty(root, "ai_summary", "aiSummary", "summary", "description", "text", "content", "response")
            ?? extractFirstStringValue(root)
            ?? ""
        result.contentType = getStringProperty(root, "content_type", "contentType", "type") ?? "other"
        result.ocrText = getStringProperty(root, "ocr_text", "ocrText", "ocr") ?? ""
        result.meetingRelevance = getStringProperty(root, "meeting_relevance", "meetingRelevance", "relevance") ?? "medium"
        result.sensitivityLevel = getStringProperty(root, "sensitivity_level", "sensitivityLevel", "sensitivity") ?? "low"
        result.activeSpeakerName = getStringProperty(root, "active_speaker_name", "activeSpeakerName", "speaker_name", "speakerName")
        result.keyEntities = getStringArray(root, "key_entities", "keyEntities")
        result.keyNumbers = getStringArray(root, "key_numbers", "keyNumbers")
        result.keyDates = getStringArray(root, "key_dates", "keyDates", "dates")
        result.slideDecisions = getStringArray(root, "slide_decisions", "slideDecisions", "decisions")
        result.slideActionItems = getStringArray(root, "slide_action_items", "slideActionItems", "action_items", "actionItems")
        result.chartType = getStringProperty(root, "chart_type", "chartType")
        result.chartInsight = getStringProperty(root, "chart_insight", "chartInsight", "key_insight", "keyInsight")
        return result
    }

    private static func getStringProperty(_ root: [String: Any], _ names: String...) -> String? {
        for name in names {
            if let val = root[name] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
        }
        return nil
    }

    private static func getStringArray(_ root: [String: Any], _ names: String...) -> [String] {
        for name in names {
            if let arr = root[name] as? [Any] {
                return arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
            }
        }
        return []
    }

    private static func extractFirstStringValue(_ value: Any) -> String? {
        if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if let obj = value as? [String: Any] {
            for (_, v) in obj {
                if let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count > 5 {
                    return s
                }
                if let nested = extractFirstStringValue(v) {
                    return nested
                }
            }
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let nested = extractFirstStringValue(item) {
                    return nested
                }
            }
        }
        return nil
    }

    private func localOcrResult(imagePath: String) async -> VisionAnalysisResult {
        guard let localOcr,
              let text = try? await localOcr.recognizeText(imagePath: imagePath),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.fallbackResult(tr("本地OCR未识别到文字", "On-device OCR recognized no text"))
        }
        var result = VisionAnalysisResult()
        result.aiSummary = tr("本地OCR提取的图中文字", "Text extracted via on-device OCR")
        result.contentType = "other"
        result.meetingRelevance = "medium"
        result.ocrText = text
        return result
    }

    private func degradedResult(_ errorHint: String, imagePath: String) async -> VisionAnalysisResult {
        guard isOcrFallbackEnabled(), let localOcr else {
            return Self.fallbackResult(errorHint)
        }
        guard let text = try? await localOcr.recognizeText(imagePath: imagePath),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.fallbackResult(errorHint)
        }
        var result = Self.fallbackResult(errorHint + tr("（已使用本地OCR兜底）", " (fell back to local OCR)"))
        result.ocrText = text
        return result
    }

    private static func fallbackResult(_ errorHint: String) -> VisionAnalysisResult {
        var result = VisionAnalysisResult()
        result.aiSummary = "[\(errorHint)]"
        result.contentType = "other"
        result.meetingRelevance = "low"
        return result
    }

    private actor Gate {
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if !held {
                held = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                held = false
            }
        }
    }
}
