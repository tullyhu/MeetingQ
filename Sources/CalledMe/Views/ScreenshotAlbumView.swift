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

    private static let selectedBorder = Color(red: 1, green: 0.702, blue: 0.278)

    public init(viewModel: ScreenshotAlbumViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            previewArea
            if viewModel.hasSelected {
                Text(viewModel.selectedTimestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.53))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            Rectangle().fill(Color(white: 0.93)).frame(height: 1)
            thumbnailStrip
        }
        .frame(width: 720, height: 520)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.88), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 28, y: 6)
        .onExitCommand { onClose() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("📷").font(.system(size: 14))
            Text(tr("截图时光轴", "Screenshot Timeline"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: 0.07))
            Text(viewModel.countLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.67))
                .padding(.leading, 2)
            Spacer()
            Button(action: onClose) {
                Text("✕")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.53))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(white: 0.88)).frame(height: 1).padding(.horizontal, 40)
        }
    }

    private var previewArea: some View {
        ZStack {
            if !viewModel.hasScreenshots {
                VStack(spacing: 10) {
                    Text("📷").font(.system(size: 32))
                    Text(tr("暂无截图", "No Screenshots"))
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.67))
                    Text(tr("开始监听后将每 30 秒自动截图", "Screenshots are taken every 30 seconds after listening starts"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.73))
                }
            } else if let img = viewModel.selectedImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.88), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(viewModel.screenshots) { item in
                    thumbnailCell(item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: 104)
        .background(Color(white: 0.96))
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
                    Color(white: 0.9)
                }
            }
            .frame(width: 120, height: 68)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(item.timeLabel)
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.53))
        }
        .padding(2)
        .background(isSelected ? Self.selectedBorder.opacity(0.1) : Color.black.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isSelected ? Self.selectedBorder : Color.clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { viewModel.select(item) }
    }
}
