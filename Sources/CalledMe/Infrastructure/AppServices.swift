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

@MainActor
public final class AppServices {
    public static let shared = AppServices()

    public let audio: AudioCaptureService
    public let asr: AsrService
    public let llm: LlmService
    public let screen: ScreenCaptureService
    public let nameDetection: NameDetectionService
    public let vision: VisionService

    private init() {
        let llm = ConfigurableLlmService()
        self.llm = llm
        self.asr = DualTrackAsrService()
        self.audio = AudioCaptureServiceImpl()
        self.screen = ScreenCaptureServiceImpl()
        self.nameDetection = NameDetectionServiceImpl(llm: llm)
        self.vision = VisionServiceImpl(llm: llm)
        self.audio.setAsr(self.asr)
    }
}
