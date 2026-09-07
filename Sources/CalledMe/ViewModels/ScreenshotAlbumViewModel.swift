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
import AppKit

@Observable
public final class AlbumScreenshotItem: Identifiable {
    public let id = UUID()
    public let filePath: String
    public let timestamp: Date
    public var thumbnail: NSImage?

    public var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }

    public init(filePath: String, timestamp: Date) {
        self.filePath = filePath
        self.timestamp = timestamp
    }
}

@MainActor
@Observable
public final class ScreenshotAlbumViewModel {
    public var screenshots: [AlbumScreenshotItem] = []
    public private(set) var selectedScreenshot: AlbumScreenshotItem?
    public var selectedImage: NSImage?

    public var hasScreenshots: Bool { !screenshots.isEmpty }
    public var hasSelected: Bool { selectedScreenshot != nil }
    public var countLabel: String { screenshots.isEmpty ? tr("暂无截图", "No Screenshots") : tr("\(screenshots.count) 张", "\(screenshots.count)") }

    public var selectedTimestamp: String {
        guard let selectedScreenshot else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        return f.string(from: selectedScreenshot.timestamp)
    }

    public init() {}

    public func load(session: MeetingSession?) {
        let shots = (session?.screenshots ?? []).sorted { $0.timestamp < $1.timestamp }
        screenshots = shots.map { AlbumScreenshotItem(filePath: $0.filePath, timestamp: $0.timestamp) }
        selectedScreenshot = nil
        selectedImage = nil
        if let last = screenshots.last {
            select(last)
        }
        loadThumbnails()
    }

    public func select(_ item: AlbumScreenshotItem) {
        selectedScreenshot = item
        selectedImage = nil
        let path = item.filePath
        Task.detached(priority: .userInitiated) {
            let img = Self.makeImage(path: path, maxWidth: 0)
            await MainActor.run { [weak self] in
                guard let self, self.selectedScreenshot?.filePath == path else { return }
                self.selectedImage = img
            }
        }
    }

    private func loadThumbnails() {
        for item in screenshots {
            let path = item.filePath
            Task.detached(priority: .utility) {
                let img = Self.makeImage(path: path, maxWidth: 240)
                await MainActor.run {
                    item.thumbnail = img
                }
            }
        }
    }

    nonisolated private static func makeImage(path: String, maxWidth: CGFloat) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let img = NSImage(contentsOfFile: path), img.size.width > 0 else { return nil }
        guard maxWidth > 0, img.size.width > maxWidth else { return img }
        let scale = maxWidth / img.size.width
        let size = NSSize(width: maxWidth, height: img.size.height * scale)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}
