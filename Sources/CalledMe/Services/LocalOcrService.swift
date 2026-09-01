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
import Vision

public final class AppleVisionOcrService: LocalOcrService, @unchecked Sendable {
    private static let maxCharacters = 2000

    public init() {}

    public func recognizeText(imagePath: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: imagePath)
            var recognized: Result<String, Error>?
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    recognized = .failure(error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                var text = lines.joined(separator: "\n")
                if text.count > Self.maxCharacters {
                    text = String(text.prefix(Self.maxCharacters))
                }
                recognized = .success(text)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(url: url)
            try handler.perform([request])
            return try (recognized ?? .success("")).get()
        }.value
    }
}
