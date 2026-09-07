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

import SwiftUI

public struct PrivacyNoticeView: View {
    public var onAccept: () -> Void

    public init(onAccept: @escaping () -> Void) {
        self.onAccept = onAccept
    }

    public static func needsShow() -> Bool {
        !KeychainStorage.loadBool(StoreKeys.privacyAccepted)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(tr("隐私说明", "Privacy Notice"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr(
                        "MeetingQ 是一款完全本地运行的会议助理，请在使用前了解以下数据处理方式：",
                        "MeetingQ is a meeting assistant that runs entirely on your Mac. Please review how your data is handled before you begin:"))
                        .font(.callout)
                        .lineSpacing(6)
                        .padding(.bottom, 14)

                    section("network", tr("网络请求", "Network Requests"), tr(
                        "会议语音在设备端实时转写，转录文本会发送至您配置的大语言模型（LLM）接口以生成摘要。API Key 以本机硬件绑定的密钥加密后存储在本机，不会明文落盘，也不会离开本机。",
                        "Meeting audio is transcribed on-device. Transcripts are sent to the LLM endpoint you configure (local or cloud) to generate summaries. API keys are encrypted with a machine-bound key and stored locally — never in plain text, never leaving this Mac."))

                    section("internaldrive", tr("本地存储", "Local Storage"), tr(
                        "转录文本、摘要、截图（JPEG）保存在本机 ~/Library/Application Support/MeetingQ/ 目录，不上传至任何服务器。",
                        "Transcripts, summaries, and screenshots (JPEG) are stored locally in ~/Library/Application Support/MeetingQ/ and are never uploaded to any server."))

                    section("mic", tr("采集范围", "What Is Captured"), tr(
                        "仅在您点击「开始监听」后采集系统音频、可选的麦克风输入，并定期截取屏幕图像。语音识别在设备端完成，不会在后台静默录音。音频仅在内存中实时用于识别，MeetingQ 不会录制或保存任何会议音视频文件，本地只保留文字转写与截图。",
                        "System audio, optional microphone input, and periodic screenshots are captured only after you press \"Start Listening\". Speech recognition runs on-device and nothing is recorded silently in the background. Audio is processed in memory only — MeetingQ never records or saves meeting audio/video files; only text transcripts and screenshots are stored locally."))

                    section("scalemass", tr("合规提示", "Legal Notice"), tr(
                        "录制会议内容可能涉及其他参会人的权益。请遵守所在地区的录音相关法律法规，并在必要时事先取得参会人的同意。",
                        "Recording meetings may affect the rights of other participants. Please comply with the recording laws in your jurisdiction and obtain consent from participants where required."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .padding(.vertical, 12)
            HStack {
                Spacer()
                Button(tr("我已阅读，开始使用", "I've Read This, Get Started"), action: accept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section(_ symbol: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(6)
        }
        .padding(.bottom, 14)
    }

    private func accept() {
        KeychainStorage.saveBool(StoreKeys.privacyAccepted, true)
        onAccept()
    }
}
