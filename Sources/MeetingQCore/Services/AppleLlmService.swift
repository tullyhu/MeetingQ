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

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleModelAvailability: Equatable, Sendable {
    case available
    case needsMacOS26
    case appleIntelligenceDisabled
    case deviceNotEligible
    case unavailable(String)

    public var isAvailable: Bool { self == .available }

    public var message: String {
        switch self {
        case .available:
            return ""
        case .needsMacOS26:
            return tr("需要 macOS 26 或更高版本", "Requires macOS 26 or later")
        case .appleIntelligenceDisabled:
            return tr("请在系统设置中开启 Apple Intelligence", "Enable Apple Intelligence in System Settings")
        case .deviceNotEligible:
            return tr("当前设备不支持 Apple Intelligence", "This device does not support Apple Intelligence")
        case .unavailable(let reason):
            return reason
        }
    }
}

public enum AppleLlmService {
    private static let chunkCharLimit = 2200

    public static func availabilityStatus() -> AppleModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceDisabled
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.modelNotReady):
                return .unavailable(tr("系统模型尚未就绪（正在下载或准备中）",
                                       "System model is not ready yet (downloading or preparing)"))
            default:
                return .unavailable(tr("系统模型不可用", "System model unavailable"))
            }
        }
        return .needsMacOS26
        #else
        return .needsMacOS26
        #endif
    }

    public static func test() async throws -> String {
        try await chat(systemPrompt: "You are a helpful assistant.", userMessage: "Reply with exactly: ok")
    }

    public static func chat(systemPrompt: String, userMessage: String) async throws -> String {
        let status = availabilityStatus()
        guard status.isAvailable else {
            throw ConfigurableLlmService.error(status.message)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: systemPrompt)
                let response = try await session.respond(to: userMessage)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                throw ConfigurableLlmService.error(generationErrorMessage(error))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ConfigurableLlmService.error(tr("系统模型请求失败：\(error.localizedDescription)",
                                                      "System model request failed: \(error.localizedDescription)"))
            }
        }
        #endif
        throw ConfigurableLlmService.error(status.message)
    }

    public static func summarize(_ transcripts: [Transcript]) async throws -> String {
        let combined = transcripts.map(\.text).joined(separator: "\n")
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "{\"summary\":\"\(tr("暂无内容", "No content"))\",\"decisions\":[]}"
        }

        let systemPrompt = tr("你是会议纪要助手，请用简洁的中文总结会议内容，只返回JSON，不要其他内容。",
                              "You are a meeting minutes assistant. Summarize the meeting concisely in English. Return JSON only, no other content.")
        let jsonFormatPrompt = tr(
            "请分析以下会议转录内容，以JSON格式返回，格式：{\"summary\":\"要点摘要\",\"decisions\":[\"决策1\",\"决策2\"]}\n\n转录内容：\n",
            "Analyze the following meeting transcript and return JSON in this format: {\"summary\":\"key points\",\"decisions\":[\"decision 1\",\"decision 2\"]}\n\nTranscript:\n")

        if combined.count <= chunkCharLimit {
            return try await chat(systemPrompt: systemPrompt, userMessage: jsonFormatPrompt + combined)
        }

        let chunks = splitTranscripts(transcripts)
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let partialPrompt = tr(
                "以下是会议转录的第 \(index + 1)/\(chunks.count) 段，请提取本段要点（要点列表，每条一句话，不超过200字）：\n",
                "Below is part \(index + 1)/\(chunks.count) of a meeting transcript. Extract the key points of this part (bullet list, one sentence each, max 200 words):\n")
            let partial = try await chat(systemPrompt: systemPrompt, userMessage: partialPrompt + chunk)
            partials.append(partial)
        }

        var mergeInput = partials.enumerated()
            .map { "[\(tr("片段", "Part")) \($0.offset + 1)]\n\($0.element)" }
            .joined(separator: "\n\n")
        if mergeInput.count > chunkCharLimit {
            mergeInput = String(mergeInput.suffix(chunkCharLimit))
        }
        let mergePrompt = tr(
            "以下是一次长会议各片段的要点，请汇总为最终会议纪要，以JSON格式返回，格式：{\"summary\":\"要点摘要\",\"decisions\":[\"决策1\",\"决策2\"]}\n\n分段要点：\n",
            "Below are the key points extracted from each part of a long meeting. Merge them into final minutes and return JSON in this format: {\"summary\":\"key points\",\"decisions\":[\"decision 1\",\"decision 2\"]}\n\nPart summaries:\n")
        return try await chat(systemPrompt: systemPrompt, userMessage: mergePrompt + mergeInput)
    }

    private static func splitTranscripts(_ transcripts: [Transcript]) -> [String] {
        var chunks: [String] = []
        var current = ""
        for t in transcripts {
            if !current.isEmpty && current.count + t.text.count + 1 > chunkCharLimit {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + t.text
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func generationErrorMessage(_ error: any Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *),
           let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return tr("内容超出系统模型上下文长度，请缩短输入或改用其他模型配置",
                          "Content exceeds the system model context window. Shorten the input or use another LLM profile")
            case .guardrailViolation:
                return tr("内容触发了系统模型的安全限制", "Content was blocked by the system model safety guardrails")
            case .unsupportedLanguageOrLocale:
                return tr("系统模型不支持当前语言", "The system model does not support the current language")
            default:
                return tr("系统模型生成失败：\(generationError.localizedDescription)",
                          "System model generation failed: \(generationError.localizedDescription)")
            }
        }
        #endif
        return error.localizedDescription
    }
}
