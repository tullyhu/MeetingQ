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

import CoreAudio
import Foundation

/// Enumerates per-process audio activity via CoreAudio process objects
/// (macOS 14.2+). This is MeetingQ's meeting-detection evidence source:
/// a meeting app holds its audio OUTPUT for the whole call, which is exactly
/// what matters for passive listeners (mic/camera may never be enabled).
///
/// Output occupancy is the primary evidence; input occupancy is only
/// a start accelerator, never end evidence.
public enum AudioProcessInspector {
    public struct ProcessAudioState: Sendable, Equatable {
        public let pid: pid_t
        /// Process is currently capturing audio input (mic held & running).
        public let runningInput: Bool
        /// Process is currently rendering audio output (playing sound).
        public let runningOutput: Bool
    }

    public static func processes() -> [ProcessAudioState] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objectIDs) == noErr else {
            return []
        }

        return objectIDs.compactMap { object in
            guard let pid: pid_t = readUInt32(object, selector: kAudioProcessPropertyPID).map({ pid_t($0) }) else {
                return nil
            }
            let input = (readUInt32(object, selector: kAudioProcessPropertyIsRunning) ?? 0) != 0
            let output = (readUInt32(object, selector: kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            return ProcessAudioState(pid: pid, runningInput: input, runningOutput: output)
        }
    }

    private static func readUInt32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
