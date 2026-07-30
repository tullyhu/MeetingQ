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

import SwiftUI
import AppKit

public struct ScreenshotAlbumView: View {
    public let viewModel: ScreenshotAlbumViewModel
    public var onClose: () -> Void

    public init(viewModel: ScreenshotAlbumViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            previewArea
            if viewModel.hasSelected {
                Text(viewModel.selectedTimestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            Divider()
            thumbnailStrip
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { onClose() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Label(tr("截图时光轴", "Screenshot Timeline"), systemImage: "photo.on.rectangle.angled")
                .font(.headline)
            Text(viewModel.countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(tr("关闭", "Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var previewArea: some View {
        ZStack {
            if !viewModel.hasScreenshots {
                ContentUnavailableView {
                    Label(tr("暂无截图", "No Screenshots"), systemImage: "photo.on.rectangle")
                } description: {
                    Text(tr("开始监听后将每 30 秒自动截图", "Screenshots are taken every 30 seconds after listening starts"))
                }
            } else if let img = viewModel.selectedImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(viewModel.screenshots) { item in
                    thumbnailCell(item)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: 104)
    }

    private func thumbnailCell(_ item: AlbumScreenshotItem) -> some View {
        let isSelected = viewModel.selectedScreenshot?.id == item.id
        return VStack(spacing: 3) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(nsColor: .controlBackgroundColor)
                }
            }
            .frame(width: 120, height: 68)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.timeLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { viewModel.select(item) }
    }
}
