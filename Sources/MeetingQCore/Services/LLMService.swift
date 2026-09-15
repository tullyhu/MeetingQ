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

public final class ConfigurableLlmService: LlmService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()

    public init() {}

    public func analyze(_ prompt: String) async throws -> String {
        try await chat(systemPrompt: tr("你是会议助手，请简洁准确地回答。",
                                        "You are a meeting assistant. Answer concisely and accurately."),
                       userMessage: prompt)
    }

    public func summarize(_ transcripts: [Transcript]) async throws -> String {
        if LlmProfileStore.active()?.provider == .apple {
            return try await AppleLlmService.summarize(transcripts)
        }
        let combined = transcripts.map(\.text).joined(separator: "\n")
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "{\"summary\":\"\(tr("暂无内容", "No content"))\",\"decisions\":[]}"
        }
        let prompt = tr(
            "请分析以下会议转录内容，以JSON格式返回，格式：{\"summary\":\"要点摘要\",\"decisions\":[\"决策1\",\"决策2\"]}\n\n转录内容：\n",
            "Analyze the following meeting transcript and return JSON in this format: {\"summary\":\"key points\",\"decisions\":[\"decision 1\",\"decision 2\"]}\n\nTranscript:\n") + combined
        return try await chat(
            systemPrompt: tr("你是会议纪要助手，请用简洁的中文总结会议内容，只返回JSON，不要其他内容。",
                             "You are a meeting minutes assistant. Summarize the meeting concisely in English. Return JSON only, no other content."),
            userMessage: prompt)
    }

    public func test() async throws -> String {
        try await chat(systemPrompt: "You are a helpful assistant.", userMessage: "Reply with exactly: ok")
    }

    public func analyzeImage(systemPrompt: String, userMessage: String, imageBase64: String, modelOverride: String?) async throws -> String {
        guard let profile = LlmProfileStore.active() else {
            throw Self.error(tr("尚未配置大模型接口，请在设置中添加并激活配置",
                                "No LLM connection configured. Add and activate a profile in Settings"))
        }
        let model = modelOverride ?? profile.visionModelId ?? profile.modelId

        if profile.provider == .apple {
            throw Self.error(tr("Apple 系统模型不支持图片分析，请在设置中改用本地 OCR 或配置 OpenAI 兼容接口",
                                "The Apple system model does not support image analysis. Use local OCR or configure an OpenAI-compatible profile in Settings"))
        }

        if profile.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Self.error(tr("Vision 接口地址未配置", "Vision base URL is not configured"))
        }
        if profile.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Self.error(tr("Vision API Key 未配置", "Vision API Key is not configured"))
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Self.error(tr("Vision 模型 ID 未配置", "Vision model ID is not configured"))
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userMessage],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(imageBase64)",
                                "detail": "low"
                            ]
                        ]
                    ]
                ]
            ],
            "max_tokens": 4096
        ]

        var request = URLRequest(url: URL(string: profile.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(profile.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)


        return try await send(request)
    }

    private func chat(systemPrompt: String, userMessage: String) async throws -> String {
        guard let profile = LlmProfileStore.active() else {
            throw Self.error(tr("尚未配置大模型接口，请在设置中添加并激活配置",
                                "No LLM connection configured. Add and activate a profile in Settings"))
        }
        if profile.provider == .apple {
            return try await AppleLlmService.chat(systemPrompt: systemPrompt, userMessage: userMessage)
        }
        if profile.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Self.error(tr("LLM 配置「\(profile.name)」的 API Key 为空",
                                "API Key is empty for LLM profile \"\(profile.name)\""))
        }
        if profile.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Self.error(tr("LLM 配置「\(profile.name)」的接口地址为空",
                                "Base URL is empty for LLM profile \"\(profile.name)\""))
        }

        let body: [String: Any] = [
            "model": profile.modelId,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": 2048
        ]

        var request = URLRequest(url: URL(string: profile.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(profile.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)


        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> String {
        do {
            let (data, response) = try await Self.session.data(for: request)
            let body = String(data: data, encoding: .utf8) ?? ""

            guard let http = response as? HTTPURLResponse else {
                throw Self.error(tr("LLM 请求失败：无效的服务器响应", "LLM request failed: invalid server response"))
            }
            guard (200...299).contains(http.statusCode) else {
                throw Self.error(tr("LLM 返回错误 (HTTP \(http.statusCode))，请检查 API Key 和接口配置：\(String(body.prefix(500)))",
                                    "LLM returned an error (HTTP \(http.statusCode)). Check your API Key and connection settings: \(String(body.prefix(500)))"))
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw Self.error(tr("LLM 响应解析失败", "Failed to parse LLM response"))
            }

            let content = Self.extractMessageContent(message)
            return content
        } catch let error as NSError where error.domain == "MeetingQ" {
            throw error
        } catch is CancellationError {
            throw Self.error(tr("LLM 请求超时，请检查网络连接", "LLM request timed out. Check your network connection"))
        } catch let urlError as URLError {
            throw Self.error(Self.friendlyMessage(for: urlError))
        } catch {
            throw Self.error(tr("LLM 请求失败：\(error.localizedDescription)", "LLM request failed: \(error.localizedDescription)"))
        }
    }

    private static func friendlyMessage(for urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return tr("LLM 请求超时，请检查网络连接", "LLM request timed out. Check your network connection")
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return tr("无法连接 LLM 服务器，请检查接口地址和网络", "Cannot connect to the LLM server. Check the base URL and your network")
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return tr("LLM 接口 SSL 证书错误，请检查接口地址是否使用有效的 HTTPS 证书",
                      "LLM endpoint SSL certificate error. Make sure the base URL uses a valid HTTPS certificate")
        case .cancelled:
            return tr("LLM 请求超时，请检查网络连接", "LLM request timed out. Check your network connection")
        default:
            return tr("LLM 请求失败：\(urlError.localizedDescription)", "LLM request failed: \(urlError.localizedDescription)")
        }
    }

    private static func extractMessageContent(_ message: [String: Any]) -> String {
        if let content = message["content"] {
            if let s = content as? String { return s }
            if let arr = content as? [Any] { return extractContentFromArray(arr) }
            if content is NSNull { return "" }
        }
        if let parts = message["content_parts"] as? [Any] {
            return extractContentFromArray(parts)
        }
        return ""
    }

    private static func extractContentFromArray(_ arr: [Any]) -> String {
        var result = ""
        for item in arr {
            if let s = item as? String {
                result += s
            } else if let obj = item as? [String: Any],
                      obj["type"] as? String == "text",
                      let text = obj["text"] as? String {
                result += text
            }
        }
        return result
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "MeetingQ", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
