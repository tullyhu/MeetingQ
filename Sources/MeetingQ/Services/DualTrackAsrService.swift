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

import AVFAudio
import Foundation

/// Runs two local ASR sessions in parallel: one for system audio (remote
/// participants) and one for the microphone (local user). System-track
/// transcripts are labeled "对方"; mic-track transcripts are labeled with the
/// configured user name (falling back to "我").
///
/// Presents a single AsrService facade so callers need no track awareness:
/// - `sendAudio(_:)` feeds the system track
/// - `sendMicAudio(_:)` feeds the mic track
/// - utteranceIds from the mic track are offset to keep the two streams distinct
public final class DualTrackAsrService: AsrService {
    public static let micUidOffset = 1_000_000

    public let systemTrack: AsrService
    public let micTrack: AsrService

    public var onTranscript: ((TranscriptEvent) -> Void)?
    public var onError: ((String) -> Void)?

    public var isConnected: Bool { systemTrack.isConnected }

    public var systemLabel: String { tr("对方", "Remote") }

    public var micLabel: String {
        let name = KeychainStorage.load(StoreKeys.userName)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? tr("我", "Me") : name
    }

    public init() {
        if #available(macOS 26.0, *) {
            systemTrack = SpeechTranscriberService()
            micTrack = SpeechTranscriberService()
        } else {
            systemTrack = LegacySpeechRecognizerService()
            micTrack = LegacySpeechRecognizerService()
        }
        systemTrack.onTranscript = { [weak self] e in
            self?.forward(e, isMic: false)
        }
        micTrack.onTranscript = { [weak self] e in
            self?.forward(e, isMic: true)
        }
        // Only system-track errors surface to the caller (they trigger a full
        // session rebuild). Mic-track errors are handled by the inner service's
        // own reconnect; mic is best-effort.
        systemTrack.onError = { [weak self] message in
            self?.onError?(message)
        }
    }

    private func forward(_ e: TranscriptEvent, isMic: Bool) {
        let uid = isMic && e.utteranceId >= 0
            ? e.utteranceId + Self.micUidOffset
            : e.utteranceId
        onTranscript?(TranscriptEvent(
            text: e.text,
            isFinal: e.isFinal,
            confidence: e.confidence,
            utteranceId: uid,
            speakerLabel: isMic ? micLabel : systemLabel))
    }

    public func connect() async throws {
        try await systemTrack.connect()
        // Mic track is best-effort: failures degrade to single-track mode
        try? await micTrack.connect()
    }

    public func sendAudio(_ buffer: AVAudioPCMBuffer) async {
        await systemTrack.sendAudio(buffer)
    }

    public func sendMicAudio(_ buffer: AVAudioPCMBuffer) async {
        guard micTrack.isConnected else { return }
        await micTrack.sendAudio(buffer)
    }

    public func finalizeSegment() async throws {
        try? await systemTrack.finalizeSegment()
        try? await micTrack.finalizeSegment()
    }

    public func disconnect() async {
        await systemTrack.disconnect()
        await micTrack.disconnect()
    }
}
