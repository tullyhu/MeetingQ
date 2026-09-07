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

public struct LanguagePickerView: View {
    public var onPicked: () -> Void

    public init(onPicked: @escaping () -> Void) {
        self.onPicked = onPicked
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.bottom, 16)
            Text("MeetingQ")
                .font(.title.weight(.bold))
                .padding(.bottom, 6)
            Text("选择语言 / Choose your language")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            HStack(spacing: 14) {
                langButton(title: "简体中文", subtitle: "Chinese", lang: .zh)
                langButton(title: "English", subtitle: "English", lang: .en)
            }
            Spacer()
        }
        .frame(width: 420, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func langButton(title: String, subtitle: String, lang: AppLanguage) -> some View {
        Button {
            AppLanguage.set(lang)
            onPicked()
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 140, height: 64)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
