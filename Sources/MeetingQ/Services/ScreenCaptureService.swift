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

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum ScreenCaptureError: LocalizedError {
    case noPermission
    case noDisplay
    case encodeFailed
    case captureFailed

    public var errorDescription: String? {
        switch self {
        case .noPermission: return tr("需要屏幕录制权限才能截图，请在系统设置→隐私与安全性→屏幕录制中允许 MeetingQ",
                                      "Screen recording permission is required to take screenshots. Allow MeetingQ in System Settings → Privacy & Security → Screen Recording")
        case .noDisplay: return tr("未找到可用显示器", "No available display found")
        case .encodeFailed: return tr("截图编码失败", "Failed to encode screenshot")
        case .captureFailed: return tr("截图失败", "Screenshot failed")
        }
    }
}

public final class ScreenCaptureServiceImpl: NSObject, ScreenCaptureService {
    public var onScreenshot: ((ScreenshotCapturedEvent) -> Void)?

    private let lock = NSLock()
    private var captureTask: Task<Void, Never>?
    private var targetWindowID: CGWindowID?
    private var lastHash: String?
    private var capturing = false

    private static let intervalNanos: UInt64 = 30 * 1_000_000_000
    private static let maxWidth = 1920
    private static let thumbW = 64
    private static let thumbH = 36
    private static let jpegQuality: CGFloat = 0.85

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturing
    }

    public func start(windowID: CGWindowID?) async throws {
        lock.lock()
        if capturing {
            lock.unlock()
            return
        }
        capturing = true
        targetWindowID = windowID
        lastHash = nil
        lock.unlock()

        do {
            _ = try await SCShareableContent.current
        } catch {
            lock.lock()
            capturing = false
            lock.unlock()
            throw ScreenCaptureError.noPermission
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let path = try await self.captureAndSave(bypassDedup: true)
            } catch {
            }
        }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.intervalNanos)
                guard !Task.isCancelled, let self else { return }
                guard self.isCapturing else { return }
                do {
                    if let path = try await self.captureAndSave(bypassDedup: false) {
                    }
                } catch {
                }
            }
        }

        lock.lock()
        captureTask = task
        lock.unlock()
    }

    public func stop() async {
        lock.lock()
        let task = captureTask
        captureTask = nil
        capturing = false
        lock.unlock()
        task?.cancel()
    }

    public func resetDuplicateState() {
        lock.lock()
        lastHash = nil
        lock.unlock()
    }

    @discardableResult
    public func takeScreenshot() async throws -> String {
        guard let path = try await captureAndSave(bypassDedup: true) else {
            throw ScreenCaptureError.captureFailed
        }
        return path
    }

    private func currentTargetWindowID() -> CGWindowID? {
        lock.lock()
        defer { lock.unlock() }
        return targetWindowID
    }

    private func captureAndSave(bypassDedup: Bool) async throws -> String? {
        let image = try await captureImage()
        let hash = Self.thumbnailHash(image)

        if !bypassDedup {
            lock.lock()
            let duplicate = hash != nil && hash == lastHash
            if !duplicate { lastHash = hash }
            lock.unlock()
            if duplicate {
                return nil
            }
        } else {
            lock.lock()
            lastHash = hash
            lock.unlock()
        }

        let timestamp = Date()
        let dir = StorageConfig.screenshotsDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("screenshot_\(Self.fileFormatter.string(from: timestamp)).jpg")
        try Self.saveJPEG(image, to: path)
        onScreenshot?(ScreenshotCapturedEvent(filePath: path, timestamp: timestamp, imageHash: hash ?? ""))
        return path
    }

    private func captureImage() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenCaptureError.noPermission
        }

        let filter: SCContentFilter
        if let windowID = currentTargetWindowID() {
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else {
                guard let display = content.displays.first else { throw ScreenCaptureError.noDisplay }
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
        } else {
            guard let display = content.displays.first else { throw ScreenCaptureError.noDisplay }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let scale = CGFloat(filter.pointPixelScale)
        let nativeW = Int(filter.contentRect.width * scale)
        let nativeH = Int(filter.contentRect.height * scale)

        let config = SCStreamConfiguration()
        config.showsCursor = false
        if nativeW > Self.maxWidth, nativeW > 0 {
            let ratio = CGFloat(Self.maxWidth) / CGFloat(nativeW)
            config.width = Self.maxWidth
            config.height = Int(CGFloat(nativeH) * ratio)
        } else {
            config.width = nativeW
            config.height = nativeH
        }

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func thumbnailHash(_ image: CGImage) -> String? {
        let w = thumbW
        let h = thumbH
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let digest = Insecure.MD5.hash(data: pixels)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func saveJPEG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenCaptureError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenCaptureError.encodeFailed
        }
    }
}
