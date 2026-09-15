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

public enum LlmProvider: String, Codable, Sendable {
    case openAICompatible = "openai"
    case apple = "apple"
}

public struct LlmProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String = ""
    public var provider: LlmProvider = .openAICompatible
    public var baseUrl: String = ""
    public var apiKey: String = ""
    public var modelId: String = ""
    public var isActive: Bool = false
    public var visionModelId: String?
    public var compressionModelId: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, baseUrl, apiKey, modelId, isActive, visionModelId, compressionModelId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        provider = try c.decodeIfPresent(LlmProvider.self, forKey: .provider) ?? .openAICompatible
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        visionModelId = try c.decodeIfPresent(String.self, forKey: .visionModelId)
        compressionModelId = try c.decodeIfPresent(String.self, forKey: .compressionModelId)
    }
}
