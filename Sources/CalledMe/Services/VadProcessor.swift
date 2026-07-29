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

import AVFAudio
import Foundation

public final class VadProcessor {
    private static let speechThreshold: Float = 0.005
    private static let silenceThreshold: Float = 0.003

    private let preRollFrames: Int
    private let postRollFrames: Int
    private let minSpeechFrames: Int
    private let frameSamples = 320

    private enum State { case silence, speech, trailing }

    private var state: State = .silence
    private var trailingCount = 0
    private var speechFrameCount = 0

    private var preRoll: [[Float]] = []
    private var accumulated: [[Float]] = []
    private var pending: [Float] = []
    private var inputFormat: AVAudioFormat?

    private var diagFrameCount = 0
    private var diagPeakRms: Float = 0

    public var onSegment: ((AVAudioPCMBuffer) -> Void)?

    public var isSpeechActive: Bool { state != .silence }

    public init(preRollMs: Int = 200, postRollMs: Int = 300, minSpeechMs: Int = 150) {
        preRollFrames = preRollMs / 20
        postRollFrames = postRollMs / 20
        minSpeechFrames = minSpeechMs / 20
    }

    public func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else {
            return
        }
        inputFormat = buffer.format
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
        while pending.count >= frameSamples {
            let frame = Array(pending[0..<frameSamples])
            pending.removeFirst(frameSamples)
            processFrame(frame)
        }
    }

    public func flush() {
        if state != .silence && speechFrameCount >= minSpeechFrames {
            emit()
        }
        accumulated.removeAll()
        preRoll.removeAll()
        state = .silence
    }

    public func reset() {
        accumulated.removeAll()
        preRoll.removeAll()
        pending.removeAll()
        state = .silence
        trailingCount = 0
        speechFrameCount = 0
        diagFrameCount = 0
        diagPeakRms = 0
    }

    private func processFrame(_ frame: [Float]) {
        let rms = calculateRms(frame)

        diagPeakRms = max(diagPeakRms, rms)
        diagFrameCount += 1
        if diagFrameCount >= 50 {
            diagFrameCount = 0
            diagPeakRms = 0
        }

        switch state {
        case .silence:
            preRoll.append(frame)
            if preRoll.count > preRollFrames {
                preRoll.removeFirst()
            }
            if rms >= Self.speechThreshold {
                state = .speech
                speechFrameCount = 0
                accumulated.append(contentsOf: preRoll)
                preRoll.removeAll()
                accumulated.append(frame)
                speechFrameCount += 1
            }

        case .speech:
            accumulated.append(frame)
            speechFrameCount += 1
            if rms < Self.silenceThreshold {
                state = .trailing
                trailingCount = 0
            }

        case .trailing:
            accumulated.append(frame)
            trailingCount += 1
            if rms >= Self.speechThreshold {
                state = .speech
                speechFrameCount += trailingCount
                trailingCount = 0
            } else if trailingCount >= postRollFrames {
                state = .silence
                if speechFrameCount >= minSpeechFrames {
                    emit()
                } else {
                    accumulated.removeAll()
                }
                preRoll.removeAll()
            }
        }
    }

    private func emit() {
        let totalSamples = accumulated.reduce(0) { $0 + $1.count }
        guard totalSamples > 0, let format = inputFormat,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else {
            accumulated.removeAll()
            return
        }
        output.frameLength = AVAudioFrameCount(totalSamples)
        if let dst = output.floatChannelData?[0] {
            var offset = 0
            for chunk in accumulated {
                chunk.withUnsafeBufferPointer { src in
                    dst.advanced(by: offset).update(from: src.baseAddress!, count: src.count)
                }
                offset += chunk.count
            }
        }
        accumulated.removeAll()
        onSegment?(output)
    }

    private func calculateRms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(frame.count)).squareRoot()
    }
}
