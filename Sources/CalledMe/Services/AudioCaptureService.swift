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
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum CaptureError: LocalizedError {
    case screenRecordingPermissionDenied
    case noDisplay
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return tr("需要屏幕录制权限才能采集系统音频，请在系统设置→隐私与安全性→屏幕录制中允许 CalledMe",
                      "Screen recording permission is required to capture system audio. Allow CalledMe in System Settings → Privacy & Security → Screen Recording")
        case .noDisplay:
            return tr("未找到可采集的显示器", "No capturable display found")
        case .streamFailed(let detail):
            return tr("系统音频采集启动失败: \(detail)", "Failed to start system audio capture: \(detail)")
        }
    }
}

enum PcmConverter {
    static func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio * 1.2) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput {
    var onAudio: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onAudio?(sampleBuffer)
    }
}

public final class AudioCaptureServiceImpl: AudioCaptureService {
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private static let frameSamples = 1600
    public var onAudioData: ((AVAudioPCMBuffer) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?
    public var onSpeechSegmentEnded: (() -> Void)?

    private let lock = NSLock()
    private let fifoLock = NSLock()
    private let captureQueue = DispatchQueue(label: "calledme.capture.sck", qos: .userInitiated)

    private var stream: SCStream?
    private var streamOutput: SystemAudioOutput?
    private var micEngine: AVAudioEngine?
    private var sysConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?

    private var _isCapturing = false
    private var micActive = false
    private var _currentDeviceName: String?
    private var _asr: AsrService?
    private var _micAsr: DualTrackAsrService?
    private var asrTail: Task<Void, Never>?
    private var micAsrTail: Task<Void, Never>?

    private var systemFifo: [Float] = []
    private var micFifo: [Float] = []

    private let vad = VadProcessor()

    private var levelFrameCount = 0
    private var levelPeakRms: Float = 0

    private var statFrames = 0
    private var statSilenceFrames = 0
    private var statBytes = 0
    private var statRmsSum: Float = 0
    private var statWindowStart = Date()

    public var isCapturing: Bool { lock.withLock { _isCapturing } }
    public var currentDeviceName: String? { lock.withLock { _currentDeviceName } }

    public init() {
        vad.onSegment = { [weak self] _ in
            guard let self else { return }
            self.onSpeechSegmentEnded?()
            let asr = self.lock.withLock { self._asr }
            if let asr {
                Task { try? await asr.finalizeSegment() }
            }
        }
    }

    public func setAsr(_ asr: AsrService?) {
        lock.withLock {
            _asr = asr
            _micAsr = asr as? DualTrackAsrService
        }
    }

    public func start() async throws {
        guard !isCapturing else {
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SystemAudioOutput()
        output.onAudio = { [weak self] sampleBuffer in
            self?.handleSystemAudio(sampleBuffer)
        }
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }

        self.stream = stream
        self.streamOutput = output

        var micStarted = false
        if KeychainStorage.loadBool(StoreKeys.micEnabled) {
            micStarted = await startMicCapture()
        }

        lock.withLock {
            _isCapturing = true
            micActive = micStarted
            _currentDeviceName = micStarted ? tr("系统音频 + 麦克风", "System Audio + Microphone") : tr("系统音频", "System Audio")
        }
        statWindowStart = Date()
    }

    public func stop() async {
        guard isCapturing else { return }

        if let stream {
            try? await stream.stopCapture()
            if let streamOutput {
                try? stream.removeStreamOutput(streamOutput, type: .audio)
            }
        }
        stream = nil
        streamOutput = nil

        if let micEngine {
            micEngine.inputNode.removeTap(onBus: 0)
            micEngine.stop()
            self.micEngine = nil
        }
        micConverter = nil
        sysConverter = nil

        vad.flush()

        fifoLock.withLock {
            systemFifo.removeAll()
            micFifo.removeAll()
        }
        lock.withLock {
            _isCapturing = false
            micActive = false
        }
    }

    private func startMicCapture() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            return false
        }
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            // Voice processing enables the OS acoustic echo canceller so the
            // remote party's voice played through speakers is not re-captured
            // by the mic. Fall back to a plain tap if unavailable.
            try? input.setVoiceProcessingEnabled(true)
            if let preferred = KeychainStorage.load(StoreKeys.micDeviceName), !preferred.isEmpty {
                if let deviceID = findInputDeviceID(matching: preferred) {
                    var id = deviceID
                    guard let audioUnit = input.audioUnit else { return false }
                    let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                                      kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                    if status != noErr {
                    }
                } else {
                }
            }
            let nativeFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: nativeFormat, to: Self.targetFormat) else {
                return false
            }
            micConverter = converter
            input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
            try engine.start()
            micEngine = engine
            return true
        } catch {
            return false
        }
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing, let converter = micConverter else { return }
        guard let converted = PcmConverter.convert(converter, input: buffer),
              let data = converted.floatChannelData else { return }
        fifoLock.withLock {
            micFifo.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
            if micFifo.count > Self.frameSamples * 20 {
                micFifo.removeFirst(micFifo.count - Self.frameSamples * 20)
            }
        }
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if sysConverter == nil || sysConverter?.inputFormat != pcm.format {
            sysConverter = AVAudioConverter(from: pcm.format, to: Self.targetFormat)
        }
        guard let converter = sysConverter,
              let converted = PcmConverter.convert(converter, input: pcm),
              let data = converted.floatChannelData else { return }

        var frames: [[Float]] = []
        fifoLock.withLock {
            systemFifo.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
            while systemFifo.count >= Self.frameSamples {
                frames.append(Array(systemFifo[0..<Self.frameSamples]))
                systemFifo.removeFirst(Self.frameSamples)
            }
        }
        for frame in frames {
            emitFrame(frame)
        }
    }

    private func emitFrame(_ systemSamples: [Float]) {
        let dualAsr = lock.withLock { _micAsr }
        var mixed = systemSamples
        var micSamples: [Float]? = nil
        if lock.withLock({ micActive }) {
            fifoLock.withLock {
                let take = min(Self.frameSamples, micFifo.count)
                if dualAsr != nil {
                    // Dual-track: keep mic audio on its own track (zero-padded)
                    var mic = [Float](repeating: 0, count: Self.frameSamples)
                    for i in 0..<take { mic[i] = micFifo[i] }
                    micSamples = mic
                }
                for i in 0..<take {
                    mixed[i] = mixed[i] * 0.5 + micFifo[i] * 0.5
                }
                if take > 0 {
                    micFifo.removeFirst(take)
                }
            }
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: AVAudioFrameCount(Self.frameSamples)) else { return }
        buffer.frameLength = AVAudioFrameCount(Self.frameSamples)
        if let dst = buffer.floatChannelData?[0] {
            mixed.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: Self.frameSamples)
            }
        }

        var sum: Float = 0
        var peak: Float = 0
        for s in mixed {
            sum += s * s
            let a = abs(s)
            if a > peak { peak = a }
        }
        let rms = (sum / Float(Self.frameSamples)).squareRoot()

        levelPeakRms = max(levelPeakRms, rms)
        levelFrameCount += 1
        if levelFrameCount >= 10 {
            onAudioLevel?(levelPeakRms)
            levelFrameCount = 0
            levelPeakRms = 0
        }

        statFrames += 1
        statBytes += Self.frameSamples * 4
        statRmsSum += rms
        if rms < 0.01 { statSilenceFrames += 1 }
        let elapsed = Date().timeIntervalSince(statWindowStart)
        if elapsed >= 30 {
            let fps = Double(statFrames) / elapsed
            let silencePct = statFrames > 0 ? Double(statSilenceFrames) * 100.0 / Double(statFrames) : 0
            let avgRms = statFrames > 0 ? statRmsSum / Float(statFrames) : 0
            statFrames = 0
            statSilenceFrames = 0
            statBytes = 0
            statRmsSum = 0
            statWindowStart = Date()
        }

        vad.process(buffer)

        let asr = lock.withLock { _asr }
        if let dualAsr, let micSamples {
            // Dual-track: system-only audio to the system track, mic-only to the mic track
            if let systemOnly = Self.makeBuffer(from: systemSamples), let asr {
                let tail = asrTail
                asrTail = Task {
                    _ = await tail?.value
                    await asr.sendAudio(systemOnly)
                }
            }
            if let micBuffer = Self.makeBuffer(from: micSamples) {
                let tail = micAsrTail
                micAsrTail = Task {
                    _ = await tail?.value
                    await dualAsr.sendMicAudio(micBuffer)
                }
            }
        } else if let asr {
            let tail = asrTail
            asrTail = Task {
                _ = await tail?.value
                await asr.sendAudio(buffer)
            }
        }

        onAudioData?(buffer)
    }

    private static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard status == noErr, sizeNeeded > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: sizeNeeded, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let srcList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let dstList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for i in 0..<min(srcList.count, dstList.count) {
            if let src = srcList[i].mData, let dst = dstList[i].mData {
                memcpy(dst, src, Int(min(srcList[i].mDataByteSize, dstList[i].mDataByteSize)))
            }
        }
        return pcm
    }

    private func findInputDeviceID(matching name: String) -> AudioDeviceID? {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                      mediaType: .audio, position: .unspecified)
        guard let device = session.devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) else { return nil }
        return audioDeviceID(forUniqueID: device.uniqueID)
    }

    private func audioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs) == noErr else { return nil }
        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var ref: Unmanaged<CFString>?
            var propSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &ref) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &propSize, ptr)
            }
            if status == noErr, let cfString = ref?.takeRetainedValue(), (cfString as String) == uniqueID {
                return deviceID
            }
        }
        return nil
    }

}
