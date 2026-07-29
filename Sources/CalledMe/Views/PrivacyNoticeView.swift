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

public struct PrivacyNoticeView: View {
    public var onAccept: () -> Void

    private static let accent = Color(red: 0.145, green: 0.388, blue: 0.922)
    private static let buttonBg = Color(red: 0.388, green: 0.4, blue: 0.945)

    public init(onAccept: @escaping () -> Void) {
        self.onAccept = onAccept
    }

    public static func needsShow() -> Bool {
        !KeychainStorage.loadBool(StoreKeys.privacyAccepted)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("🔒  隐私说明", "🔒  Privacy Notice"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Self.buttonBg)
                Rectangle().fill(Color(white: 0.93)).frame(height: 1)
            }
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr(
                        "CalledMe 是一款完全本地运行的会议助理，请在使用前了解以下数据处理方式：",
                        "CalledMe is a meeting assistant that runs entirely on your Mac. Please review how your data is handled before you begin:"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.2))
                        .lineSpacing(9)
                        .padding(.bottom, 14)

                    sectionHeader(tr("📡  网络请求", "📡  Network Requests"))
                    Text(tr(
                        "会议语音在设备端实时转写，转录文本会发送至您配置的大语言模型（LLM）接口以生成摘要。所有 API Key 存储在 macOS 系统钥匙串中，不会离开本机。",
                        "Meeting audio is transcribed on-device. Transcripts are sent to the LLM endpoint you configure (local or cloud) to generate summaries. API keys are stored in the macOS Keychain and never leave this Mac."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.33))
                        .lineSpacing(8)
                        .padding(.bottom, 14)

                    sectionHeader(tr("💾  本地存储", "💾  Local Storage"))
                    Text(tr(
                        "转录文本、摘要、截图（JPEG）保存在本机 ~/Library/Application Support/CalledMe/ 目录，不上传至任何服务器。",
                        "Transcripts, summaries, and screenshots (JPEG) are stored locally in ~/Library/Application Support/CalledMe/ and are never uploaded to any server."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.33))
                        .lineSpacing(8)
                        .padding(.bottom, 14)

                    sectionHeader(tr("🎤  采集范围", "🎤  What Is Captured"))
                    Text(tr(
                        "仅在您点击「开始监听」后采集系统音频、可选的麦克风输入，并定期截取屏幕图像。语音识别在设备端完成，不会在后台静默录音。音频仅在内存中实时用于识别，CalledMe 不会录制或保存任何会议音视频文件，本地只保留文字转写与截图。",
                        "System audio, optional microphone input, and periodic screenshots are captured only after you press \"Start Listening\". Speech recognition runs on-device and nothing is recorded silently in the background. Audio is processed in memory only — CalledMe never records or saves meeting audio/video files; only text transcripts and screenshots are stored locally."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.33))
                        .lineSpacing(8)
                        .padding(.bottom, 14)

                    sectionHeader(tr("⚖️  合规提示", "⚖️  Legal Notice"))
                    Text(tr(
                        "录制会议内容可能涉及其他参会人的权益。请遵守所在地区的录音相关法律法规，并在必要时事先取得参会人的同意。",
                        "Recording meetings may affect the rights of other participants. Please comply with the recording laws in your jurisdiction and obtain consent from participants where required."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.33))
                        .lineSpacing(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 16) {
                Rectangle().fill(Color(white: 0.93)).frame(height: 1)
                HStack {
                    Spacer()
                    Button(action: accept) {
                        Text(tr("我已阅读，开始使用", "I've Read This, Get Started"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 9)
                            .background(Self.buttonBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 20)
        }
        .padding(32)
        .frame(width: 480, height: 470)
        .background(Color.white)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Self.accent)
            .padding(.bottom, 4)
    }

    private func accept() {
        KeychainStorage.saveBool(StoreKeys.privacyAccepted, true)
        onAccept()
    }
}
