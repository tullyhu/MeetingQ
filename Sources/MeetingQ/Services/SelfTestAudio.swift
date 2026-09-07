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

import AVFoundation

public enum SelfTestAudio {
    public static let phraseZh = "会议助手功能自检，一二三，四五六，语音识别测试完成。"
    public static let phraseEn = "MeetingQ self test. One two three, four five six, speech recognition test complete."

    private static var synthesizer: AVSpeechSynthesizer?

    public static func speak() {
        let utterance: AVSpeechUtterance
        if AppLanguage.current.isEnglish {
            utterance = AVSpeechUtterance(string: phraseEn)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        } else if let zhVoice = AVSpeechSynthesisVoice(language: "zh-CN") {
            utterance = AVSpeechUtterance(string: phraseZh)
            utterance.voice = zhVoice
        } else {
            utterance = AVSpeechUtterance(string: phraseEn)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8
        utterance.volume = 0.85

        let synth = AVSpeechSynthesizer()
        synthesizer = synth
        synth.speak(utterance)
    }

    public static func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }
}
