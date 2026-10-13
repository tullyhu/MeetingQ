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

import AppKit
import Foundation
import MeetingQCore
import UserNotifications

/// Automatic meeting detection for the passive-listening scenario.
///
/// Evidence model (see docs/meeting_auto_detect_spec.md):
/// - Candidate: a known meeting app has a window, or a browser tab matches a
///   meeting URL pattern.
/// - Start evidence: the candidate's process holds audio OUTPUT (meeting apps
///   hold output for the whole call — works for muted, camera-off listeners).
///   Input occupancy or visible call controls accelerate confirmation but are
///   never required and never used for end detection.
/// - Hard end: the monitored window object is destroyed (mini-window and
///   minimize do NOT count — the CGWindowID persists).
/// - Soft end: output released for a grace period → ask the user, never
///   auto-stop while listening is still physically possible.
@MainActor
public final class MeetingWatcherService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = MeetingWatcherService()

    public enum Mode: String, CaseIterable, Sendable {
        case off, prompt, auto

        public var displayName: String {
            switch self {
            case .off: tr("关闭", "Off")
            case .prompt: tr("仅提示", "Prompt Only")
            case .auto: tr("自动开始", "Auto Start")
            }
        }
    }

    // MARK: - Tunables

    private static let pollInterval: TimeInterval = 5
    /// Two consecutive hits confirm a start (stale evidence can't mint a meeting).
    private static let confirmHitsRequired = 2
    /// Output released this long before the soft-end prompt appears.
    private static let softEndGrace: TimeInterval = 60
    /// After any stop of a detected meeting, don't re-detect for this long.
    private static let cooldownAfterStop: TimeInterval = 600
    /// Re-teach the same unknown app at most once per day.
    private static let teachCooldown: TimeInterval = 86400

    // MARK: - Platform profiles (data-driven; extend by adding rows)

    public struct Profile: Sendable {
        public let name: String
        public let bundleIDs: [String]
        public let processNames: [String]
        public let urlPatterns: [String]
    }

    public static let builtInProfiles: [Profile] = [
        Profile(name: "Zoom", bundleIDs: ["us.zoom.xos"], processNames: ["zoom.us"], urlPatterns: ["zoom.us/j/", "zoom.us/wc/"]),
        Profile(name: "腾讯会议", bundleIDs: ["com.tencent.meeting"], processNames: ["wemeetapp"], urlPatterns: ["meeting.tencent.com", "voovmeeting.com"]),
        Profile(name: "飞书", bundleIDs: ["com.lark.feishu", "com.bytedance.lark.mac", "com.lark.lark"], processNames: [], urlPatterns: ["vc.feishu.cn", "vc.larksuite.com"]),
        Profile(name: "钉钉", bundleIDs: ["com.alibaba.DingTalkMac"], processNames: [], urlPatterns: ["meeting.dingtalk.com"]),
        Profile(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"], processNames: [], urlPatterns: ["teams.microsoft.com", "teams.live.com"]),
        Profile(name: "Webex", bundleIDs: ["com.cisco.webex.meetings", "com.webex.meetingmanager"], processNames: [], urlPatterns: ["webex.com/meet", ".webex.com"]),
        Profile(name: "FaceTime", bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"], processNames: ["avconferenced"], urlPatterns: []),
    ]

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "org.mozilla.firefox", "com.vivaldi.Vivaldi",
    ]

    /// Always-on system daemons whose audio activity is ambient noise.
    /// NOTE: avconferenced is deliberately NOT excluded — it IS FaceTime's
    /// audio engine and only runs during calls.
    private static let excludedBundleIDs: Set<String> = ["com.apple.corespeech"]

    // MARK: - State

    private enum State: Equatable {
        case idle
        case confirming(pid: pid_t, title: String, platform: String, hits: Int, accelerated: Bool)
        case inMeeting(pid: pid_t)
        case cooldown(until: Date)
    }
    private var state: State = .idle

    /// Set by FloatingWindowViewModel via notifications.
    public private(set) var isMonitoring = false
    public private(set) var monitoredWindowID: CGWindowID?

    private var pollTimer: Timer?
    private var outputMissingSince: Date?
    private var softEndPrompted = false
    private var lastTeachAt: [String: Date] = [:] // bundleID -> last prompt time

    public var mode: Mode {
        Mode(rawValue: KeychainStorage.load(StoreKeys.meetingAutoDetectMode) ?? Mode.prompt.rawValue) ?? .prompt
    }

    public func setMode(_ mode: Mode) {
        KeychainStorage.save(StoreKeys.meetingAutoDetectMode, value: mode.rawValue)
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(onMonitoringChanged(_:)),
                                               name: .mmMonitoringStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onCaptureWindowChanged(_:)),
                                               name: .mmCaptureWindowChanged, object: nil)
    }

    public func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: - Notifications from the app

    @objc private func onMonitoringChanged(_ note: Notification) {
        let monitoring = (note.object as? Bool) ?? false
        let wasMonitoring = isMonitoring
        isMonitoring = monitoring
        if wasMonitoring, !monitoring {
            // Any stop of a detected meeting starts the cooldown so we never
            // fight the user's manual stop.
            if case .inMeeting = state { state = .cooldown(until: Date().addingTimeInterval(Self.cooldownAfterStop)) }
            outputMissingSince = nil
            softEndPrompted = false
        }
    }

    @objc private func onCaptureWindowChanged(_ note: Notification) {
        monitoredWindowID = (note.object as? NSNumber)?.uint32Value
    }

    // MARK: - Poll

    private func poll() {
        if isMonitoring {
            pollWhileMonitoring()
        } else {
            pollWhileIdle()
        }
    }

    // MARK: While monitoring: end detection

    private func pollWhileMonitoring() {
        // Hard end: the monitored window object is gone. Mini-windows and
        // minimize keep the ID; only destruction reaches here.
        if let id = monitoredWindowID, !WindowListHelper.windowExists(id) {
            state = .cooldown(until: Date().addingTimeInterval(Self.cooldownAfterStop))
            NotificationCenter.default.post(name: .mmMeetingWindowClosed, object: nil)
            return
        }

        // Soft end: meeting app's output released for the grace period.
        guard case .inMeeting(let pid) = state else { return }
        let stillPlaying = AudioProcessInspector.processes().contains { $0.pid == pid && $0.runningOutput }
        if stillPlaying {
            outputMissingSince = nil
            return
        }
        let since = outputMissingSince ?? Date()
        outputMissingSince = since
        if !softEndPrompted, Date().timeIntervalSince(since) >= Self.softEndGrace {
            softEndPrompted = true
            sendEndPrompt()
        }
    }

    // MARK: While idle: start detection

    private func pollWhileIdle() {
        guard mode != .off else { state = .idle; return }
        if case .cooldown(let until) = state, Date() < until { return }
        state = .idle

        guard let candidate = detectCandidate() else {
            state = .idle
            return
        }

        switch state {
        case .confirming(let pid, let title, let platform, let hits, let accelerated)
        where pid == candidate.pid:
            let confirmed = accelerated || hits + 1 >= Self.confirmHitsRequired
            if confirmed {
                state = .inMeeting(pid: pid)
                triggerStart(title: title, platform: platform, pid: pid)
            } else {
                state = .confirming(pid: pid, title: title, platform: platform, hits: hits + 1, accelerated: accelerated)
            }
        default:
            state = .confirming(pid: candidate.pid, title: candidate.title,
                                platform: candidate.platform, hits: 1,
                                accelerated: candidate.accelerated)
        }
    }

    private struct Candidate {
        let pid: pid_t
        let title: String
        let platform: String
        /// Input held or call controls visible — one hit is enough to confirm.
        let accelerated: Bool
    }

    private func detectCandidate() -> Candidate? {
        let audioStates = AudioProcessInspector.processes()
        let windows = WindowListHelper.listWindows()

        for audio in audioStates where audio.runningOutput {
            guard let app = NSRunningApplication(processIdentifier: audio.pid),
                  let bundleID = app.bundleIdentifier else { continue }
            if Self.excludedBundleIDs.contains(bundleID) { continue }

            // Browser: needs URL evidence.
            if Self.browserBundleIDs.contains(bundleID) {
                if let (platform, title) = resolveBrowserCandidate(app: app) {
                    return Candidate(pid: audio.pid, title: title, platform: platform,
                                     accelerated: audio.runningInput)
                }
                continue
            }

            if let profile = profile(for: bundleID, processName: app.localizedName ?? "") {
                let title = windows.first { $0.ownerName == (app.localizedName ?? "") }?.title
                    ?? app.localizedName ?? profile.name
                let accelerated = audio.runningInput
                    || ActiveSpeakerAxService.hasCallControls(ownerName: app.localizedName ?? "")
                return Candidate(pid: audio.pid, title: title, platform: profile.name,
                                 accelerated: accelerated)
            }

            // Unknown app holding BOTH input and output: a call signature.
            // Ask once per app per day; "yes" teaches the profile list.
            if audio.runningInput {
                maybeTeachUnknownApp(app: app, bundleID: bundleID)
            }
        }
        return nil
    }

    private func profile(for bundleID: String, processName: String) -> Profile? {
        let learned = learnedBundleIDs()
        return Self.builtInProfiles.first {
            $0.bundleIDs.contains(bundleID) || $0.processNames.contains(processName)
        } ?? (learned.contains(bundleID)
              ? Profile(name: processName, bundleIDs: [bundleID], processNames: [], urlPatterns: [])
              : nil)
    }

    // MARK: Browser URL evidence

    private func resolveBrowserCandidate(app: NSRunningApplication) -> (platform: String, title: String)? {
        guard AXIsProcessTrusted() else { return nil }
        let url = browserFocusedURL(pid: app.processIdentifier)?.lowercased() ?? ""
        guard !url.isEmpty else { return nil }
        for profile in Self.builtInProfiles {
            if profile.urlPatterns.contains(where: { url.contains($0.lowercased()) }) {
                let title = WindowListHelper.listWindows().first { $0.ownerName == (app.localizedName ?? "") }?.title
                    ?? profile.name
                return (profile.name, title)
            }
        }
        return nil
    }

    /// Reads the focused window's URL from the browser's AX tree.
    private func browserFocusedURL(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        // Safari/Chrome expose AXURL on the window; others put it on the web area.
        if let url = axURL(of: window as! AXUIElement) { return url }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list.prefix(8) {
            if let url = axURL(of: child) { return url }
        }
        return nil
    }

    private func axURL(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    // MARK: Start / prompts

    private func triggerStart(title: String, platform: String, pid: pid_t) {
        switch mode {
        case .off:
            break
        case .auto:
            NotificationCenter.default.post(name: .mmAutoStartMeeting,
                                            object: nil,
                                            userInfo: ["title": title])
        case .prompt:
            sendStartPrompt(title: title, platform: platform)
        }
    }

    private func notificationCenter() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    private func requestNotificationPermissionIfNeeded() {
        notificationCenter().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendStartPrompt(title: String, platform: String) {
        requestNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = tr("检测到会议", "Meeting Detected")
        content.body = String(format: tr("%@ 正在进行：%@", "%@ in progress: %@"), platform, title)
        content.categoryIdentifier = "MEETING_START"
        content.userInfo = ["title": title]
        notificationCenter().add(UNNotificationRequest(identifier: "meeting-start",
                                                       content: content, trigger: nil))
    }

    private func sendEndPrompt() {
        requestNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = tr("会议可能已结束", "Meeting May Have Ended")
        content.body = tr("对方声音已停止 1 分钟。要结束监听并生成纪要吗？",
                          "Remote audio stopped 1 minute ago. Stop listening and generate minutes?")
        content.categoryIdentifier = "MEETING_END"
        notificationCenter().add(UNNotificationRequest(identifier: "meeting-end",
                                                       content: content, trigger: nil))
    }

    // MARK: User-taught platforms

    private func learnedBundleIDs() -> Set<String> {
        guard let raw = KeychainStorage.load(StoreKeys.meetingLearnedApps),
              let arr = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
        return Set(arr)
    }

    public func teachBundleID(_ bundleID: String) {
        var set = learnedBundleIDs()
        set.insert(bundleID)
        if let data = try? JSONEncoder().encode(Array(set)) {
            KeychainStorage.save(StoreKeys.meetingLearnedApps, value: String(data: data, encoding: .utf8) ?? "[]")
        }
    }

    private func maybeTeachUnknownApp(app: NSRunningApplication, bundleID: String) {
        if let last = lastTeachAt[bundleID], Date().timeIntervalSince(last) < Self.teachCooldown { return }
        lastTeachAt[bundleID] = Date()
        requestNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = tr("正在开会吗？", "In a Meeting?")
        content.body = String(format: tr("「%@」正在使用音频输入和输出。要在检测到它时自动识别为会议吗？", "\"%@\" is using audio input and output. Recognize it as a meeting app?"),
                              app.localizedName ?? bundleID)
        content.categoryIdentifier = "MEETING_TEACH"
        content.userInfo = ["bundleID": bundleID]
        notificationCenter().add(UNNotificationRequest(identifier: "meeting-teach-\(bundleID)",
                                                       content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func registerNotificationCategories() {
        let start = UNNotificationAction(identifier: "START", title: tr("开始监听", "Start Listening"))
        let ignore = UNNotificationAction(identifier: "IGNORE", title: tr("忽略", "Ignore"))
        let end = UNNotificationAction(identifier: "END", title: tr("结束并生成纪要", "End & Generate Minutes"))
        let keep = UNNotificationAction(identifier: "KEEP", title: tr("继续监听", "Keep Listening"))
        let teach = UNNotificationAction(identifier: "TEACH", title: tr("识别为会议软件", "Recognize as Meeting App"))
        let no = UNNotificationAction(identifier: "NO", title: tr("不了", "No"))
        notificationCenter().setNotificationCategories([
            UNNotificationCategory(identifier: "MEETING_START", actions: [start, ignore], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MEETING_END", actions: [end, keep], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MEETING_TEACH", actions: [teach, no], intentIdentifiers: []),
        ])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        Task { @MainActor in
            switch (category, action) {
            case ("MEETING_START", "START"):
                NotificationCenter.default.post(name: .mmAutoStartMeeting, object: nil, userInfo: info)
            case ("MEETING_END", "END"):
                NotificationCenter.default.post(name: .mmMeetingEndConfirmed, object: nil)
            case ("MEETING_TEACH", "TEACH"):
                if let bundleID = info["bundleID"] as? String { teachBundleID(bundleID) }
            default:
                break
            }
            completionHandler()
        }
    }
}
