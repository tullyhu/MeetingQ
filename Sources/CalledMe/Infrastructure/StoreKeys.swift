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

public enum StoreKeys {
    public static let userName = "user_name"
    public static let userNicknames = "user_nicknames"
    public static let userAsrVariants = "user_asr_variants"
    public static let userRole = "user_role"
    public static let llmProfiles = "llm_profiles"
    public static let captureWindowTitle = "capture_window_title"
    public static let micEnabled = "mic_enabled"
    public static let micDeviceName = "mic_device_name"
    public static let privacyAccepted = "privacy_accepted"
    public static let multimodalEnabled = "multimodal_enabled"
    public static let appLanguage = "app_language"
    public static let onboardingDone = "onboarding_done"
    public static let showDockIcon = "show_dock_icon"

    public static let all = [
        userName, userNicknames, userAsrVariants, userRole, llmProfiles,
        captureWindowTitle, micEnabled, micDeviceName, privacyAccepted,
        multimodalEnabled, appLanguage, onboardingDone, showDockIcon,
    ]
}
