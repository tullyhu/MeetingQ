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

import AppKit
import Foundation

@Observable
public final class LlmProfileItem: Identifiable {
    public let id: UUID
    public var name: String = ""
    public var baseUrl: String = ""
    public var apiKey: String = ""
    public var modelId: String = ""
    public var isActive: Bool = false
    public var visionModelId: String = ""
    public var compressionModelId: String = ""

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public func toModel() -> LlmProfile {
        var p = LlmProfile()
        p.id = id
        p.name = name
        p.baseUrl = baseUrl
        p.apiKey = apiKey
        p.modelId = modelId
        p.isActive = isActive
        p.visionModelId = visionModelId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : visionModelId
        p.compressionModelId = compressionModelId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : compressionModelId
        return p
    }

    public static func fromModel(_ p: LlmProfile) -> LlmProfileItem {
        let item = LlmProfileItem(id: p.id)
        item.name = p.name
        item.baseUrl = p.baseUrl
        item.apiKey = p.apiKey
        item.modelId = p.modelId
        item.isActive = p.isActive
        item.visionModelId = p.visionModelId ?? ""
        item.compressionModelId = p.compressionModelId ?? ""
        return item
    }
}

private struct TimeoutError: LocalizedError {
    let seconds: Int
    var errorDescription: String? { tr("操作超时（\(seconds)s）", "Operation timed out (\(seconds)s)") }
}

private struct ModelsResponse: Decodable {
    struct Entry: Decodable { let id: String? }
    let data: [Entry]
}

@MainActor
@Observable
public final class SettingsViewModel {
    public var userName: String = ""
    public var userNicknames: String = ""
    public var userAsrVariants: String = ""
    public var userRole: String = ""
    public var isGeneratingAsrVariants: Bool = false
    public var asrVariantsError: String = ""
    public var hasAsrVariantsError: Bool { !asrVariantsError.isEmpty }

    public var micEnabled: Bool = false
    public var micDeviceName: String = ""

    public var llmProfiles: [LlmProfileItem] = []
    public var selectedProfile: LlmProfileItem?
    public var availableModels: [String] = []
    public var isFetchingModels: Bool = false
    public var hasSelectedProfile: Bool { selectedProfile != nil }

    public var selectedProfileId: UUID? {
        get { selectedProfile?.id }
        set { selectedProfile = llmProfiles.first(where: { $0.id == newValue }) }
    }

    public var dataDirectory: String = "" {
        didSet { dataDirStatus = "" }
    }
    public var dataDirStatus: String = ""
    public var isDataDirDefault: Bool { dataDirectory == StorageConfig.anchorDir }

    public var connectionTestResult: String = ""
    public var asrTestResult: String = ""
    public var hasConnectionTestResult: Bool { !connectionTestResult.isEmpty }
    public var hasAsrTestResult: Bool { !asrTestResult.isEmpty }

    public var statusMessage: String = ""

    public var statsSessions: String = "—"
    public var statsTotalTime: String = "—"
    public var statsTranscripts: String = "—"
    public var statsScreenshots: String = "—"
    public var statsLoading: Bool = false

    private var savedDataDirectory: String = ""

    public init() {
        loadFromStorage()
    }

    public func loadFromStorage() {
        userName = KeychainStorage.load(StoreKeys.userName) ?? ""
        userNicknames = KeychainStorage.load(StoreKeys.userNicknames) ?? ""
        userAsrVariants = KeychainStorage.load(StoreKeys.userAsrVariants) ?? ""
        userRole = KeychainStorage.load(StoreKeys.userRole) ?? ""

        micEnabled = KeychainStorage.loadBool(StoreKeys.micEnabled)
        micDeviceName = KeychainStorage.load(StoreKeys.micDeviceName) ?? ""

        dataDirectory = StorageConfig.storageDir
        savedDataDirectory = dataDirectory
        dataDirStatus = ""

        llmProfiles = LlmProfileStore.load().map { LlmProfileItem.fromModel($0) }
        selectedProfile = llmProfiles.first(where: \.isActive) ?? llmProfiles.first
    }

    // MARK: - LLM profiles

    public func addProfile() {
        let item = LlmProfileItem()
        item.name = tr("新配置", "New Profile")
        item.baseUrl = "https://api.openai.com/v1"
        item.modelId = "gpt-4o-mini"
        llmProfiles.append(item)
        selectedProfile = item
    }

    public func deleteProfile() {
        guard let sel = selectedProfile, let idx = llmProfiles.firstIndex(where: { $0.id == sel.id }) else { return }
        llmProfiles.remove(at: idx)
        selectedProfile = llmProfiles.isEmpty ? nil : llmProfiles[min(idx, llmProfiles.count - 1)]
        ensureOneActive()
    }

    public func setActiveProfile() {
        guard let sel = selectedProfile else { return }
        for p in llmProfiles { p.isActive = false }
        sel.isActive = true
    }

    private func ensureOneActive() {
        guard !llmProfiles.isEmpty, !llmProfiles.contains(where: \.isActive) else { return }
        llmProfiles[0].isActive = true
    }

    public var canFetchModels: Bool {
        !isFetchingModels && selectedProfile != nil
            && !(selectedProfile?.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    public func fetchModels() {
        guard canFetchModels, let profile = selectedProfile else { return }
        isFetchingModels = true
        availableModels = []
        var base = profile.baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        let apiKey = profile.apiKey
        Task {
            defer { isFetchingModels = false }
            do {
                guard let url = URL(string: "\(base)/models") else {
                    throw NSError(domain: "SettingsViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("Base URL 无效", "Invalid Base URL")])
                }
                var req = URLRequest(url: url)
                req.timeoutInterval = 10
                if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "SettingsViewModel", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                }
                let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
                let models = decoded.data.compactMap(\.id).filter { !$0.isEmpty }.sorted()
                availableModels = models
            } catch {
                availableModels = [tr("(获取失败：\(error.localizedDescription))", "(Fetch failed: \(error.localizedDescription))")]
            }
        }
    }

    // MARK: - Data directory

    public func browseDataDirectory() {
        let panel = NSOpenPanel()
        panel.title = tr("选择 CalledMe 数据存储目录", "Choose CalledMe Data Storage Directory")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: dataDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            dataDirectory = url.path
        }
    }

    public func openDataDirectory() {
        let dir = FileManager.default.fileExists(atPath: dataDirectory) ? dataDirectory : StorageConfig.storageDir
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    public func migrateDataDirectory() {
        let current = StorageConfig.storageDir
        guard !dataDirectory.trimmingCharacters(in: .whitespaces).isEmpty, dataDirectory != current else {
            dataDirStatus = tr("目录未变更，无需迁移", "Directory unchanged, no migration needed")
            return
        }
        do {
            try StorageConfig.migrateData(from: current, to: dataDirectory)
            try StorageConfig.setStorageDir(dataDirectory)
            savedDataDirectory = dataDirectory
            dataDirStatus = tr("数据已迁移到新目录，重启应用后完全生效", "Data migrated to the new directory. Fully effective after restart")
        } catch {
            dataDirStatus = tr("迁移失败：\(error.localizedDescription)", "Migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear config

    public func clearAllConfig() {
        KeychainStorage.clearAll()
        LlmProfileStore.save([])
        loadFromStorage()
        AppServices.shared.nameDetection.reloadNames()
        dataDirStatus = tr("配置已清空", "Configuration cleared")
    }

    // MARK: - Save

    public func saveSettings() {

        KeychainStorage.save(StoreKeys.userName, value: userName)
        KeychainStorage.save(StoreKeys.userNicknames, value: userNicknames)
        KeychainStorage.save(StoreKeys.userAsrVariants, value: userAsrVariants)
        KeychainStorage.save(StoreKeys.userRole, value: userRole)
        KeychainStorage.saveBool(StoreKeys.micEnabled, micEnabled)
        KeychainStorage.save(StoreKeys.micDeviceName, value: micDeviceName)

        let currentDir = StorageConfig.storageDir
        if !dataDirectory.trimmingCharacters(in: .whitespaces).isEmpty, dataDirectory != currentDir {
            do {
                try StorageConfig.setStorageDir(dataDirectory)
            } catch {
                dataDirStatus = tr("保存数据目录失败：\(error.localizedDescription)", "Failed to save data directory: \(error.localizedDescription)")
            }
        }

        ensureOneActive()
        LlmProfileStore.save(llmProfiles.map { $0.toModel() })

        AppServices.shared.nameDetection.reloadNames()

        if dataDirectory != savedDataDirectory {
            savedDataDirectory = dataDirectory
            statusMessage = tr("设置已保存。数据目录已更改，重启应用后完全生效",
                               "Settings saved. Data directory changed; fully effective after restart")
        } else {
            statusMessage = tr("设置已保存 ✓", "Settings saved ✓")
        }
    }

    // MARK: - ASR variants

    public var canGenerateAsrVariants: Bool {
        !isGeneratingAsrVariants
            && (!userName.trimmingCharacters(in: .whitespaces).isEmpty
                || !userNicknames.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    public func generateAsrVariants() {
        guard canGenerateAsrVariants else { return }
        isGeneratingAsrVariants = true
        asrVariantsError = ""

        var names: [String] = []
        if !userName.trimmingCharacters(in: .whitespaces).isEmpty {
            names += userName.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if !userNicknames.trimmingCharacters(in: .whitespaces).isEmpty {
            names += userNicknames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let namesText = names.joined(separator: tr("、", ", "))
        let prompt: String
        if AppLanguage.current.isEnglish {
            prompt = """
            The user's name/nicknames used in meetings: \(namesText)

            List common words that speech recognition (ASR) might mishear each of these names as.
            Misrecognition usually comes from similar pronunciation or common homophones.

            Requirements:
            - List 2-4 most likely misheard words for each name
            - Only list common words with similar pronunciation, no explanations
            - Return only a comma-separated list of words, nothing else

            Return only the word list:
            """
        } else {
            prompt = """
            用户在会议中使用的姓名/昵称为：\(namesText)

            请列举中文语音识别（ASR）可能将上述每个名字误识别成的常见词语。
            误识别原因通常是：声调不同、声母/韵母相近、读音相似的常用词。

            要求：
            - 每个名字列举 2～4 个最可能被误识别成的词
            - 只列举读音相近的常用汉语词汇，不需要解释
            - 只返回逗号分隔的词列表，不要任何其他内容

            只返回词列表：
            """
        }

        let llm = AppServices.shared.llm
        Task {
            defer { isGeneratingAsrVariants = false }
            do {
                let reply = try await withTimeout(60) { try await llm.analyze(prompt) }
                let separators = CharacterSet(charactersIn: ",，\n\r、;； ")
                let trimChars = CharacterSet(charactersIn: "。！？\"“”'\" \t")
                var seen = Set<String>()
                let variants = reply.components(separatedBy: separators)
                    .map { $0.trimmingCharacters(in: trimChars) }
                    .map { component -> String in
                        if let idx = component.lastIndex(of: "：") ?? component.lastIndex(of: ":") {
                            return String(component[component.index(after: idx)...])
                        }
                        return component
                    }
                    .filter { (1...6).contains($0.count) }
                    .filter { seen.insert($0).inserted }
                if !variants.isEmpty {
                    userAsrVariants = variants.joined(separator: ",")
                } else {
                    asrVariantsError = tr("LLM 未返回有效结果，请重试", "LLM returned no valid result. Please try again")
                }
            } catch is TimeoutError {
                asrVariantsError = tr("生成超时（60s），请检查 LLM 连接后重试", "Generation timed out (60s). Check the LLM connection and try again")
            } catch {
                asrVariantsError = tr("生成失败：\(error.localizedDescription)", "Generation failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Connection tests

    public func testConnection() {
        connectionTestResult = tr("测试中...", "Testing...")
        ensureOneActive()
        LlmProfileStore.save(llmProfiles.map { $0.toModel() })
        let llm = AppServices.shared.llm
        Task {
            do {
                let reply = try await withTimeout(15) { try await llm.test() }
                connectionTestResult = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? tr("LLM 无响应，请检查接口地址和 API Key", "LLM not responding. Check the base URL and API Key")
                    : tr("LLM 连接成功 ✓", "LLM connection successful ✓")
            } catch is TimeoutError {
                connectionTestResult = tr("LLM 失败：连接超时（15s）", "LLM failed: connection timed out (15s)")
            } catch {
                connectionTestResult = tr("LLM 失败：\(error.localizedDescription)", "LLM failed: \(error.localizedDescription)")
            }
        }
    }

    public func testAsrConnection() {
        asrTestResult = tr("测试中...", "Testing...")
        let asr = AppServices.shared.asr
        Task {
            do {
                try await withTimeout(30) {
                    try await asr.connect()
                    await asr.disconnect()
                }
                asrTestResult = tr("本地 ASR 初始化成功 ✓", "Local ASR initialized successfully ✓")
            } catch is TimeoutError {
                asrTestResult = tr("ASR 超时：初始化超过 30s", "ASR timed out: initialization took over 30s")
            } catch {
                asrTestResult = tr("ASR 失败：\(error.localizedDescription)", "ASR failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Stats

    public func loadStats() {
        statsLoading = true
        let sessions = DataStore.shared.countSessions()
        let transcripts = DataStore.shared.countTranscripts()
        let screenshots = DataStore.shared.countScreenshots()
        let totalSecs = Double(DataStore.shared.totalMeetingSeconds())
        let h = Int(totalSecs / 3600)
        let m = Int(totalSecs.truncatingRemainder(dividingBy: 3600) / 60)
        statsSessions = tr("\(sessions) 次", "\(sessions)")
        statsTotalTime = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        statsTranscripts = tr("\(transcripts) 条", "\(transcripts)")
        statsScreenshots = tr("\(screenshots) 张", "\(screenshots)")
        statsLoading = false
    }

    // MARK: - Data clearing

    public func clearTranscriptHistory() {
        DataStore.shared.deleteTranscriptHistory()
        statusMessage = tr("转录历史已清空", "Transcript history cleared")
        loadStats()
    }

    public func clearScreenshotHistory() {
        let paths = DataStore.shared.allScreenshotPaths()
        DataStore.shared.deleteAllScreenshots()

        var deleted = 0
        let fm = FileManager.default
        for path in paths where !path.isEmpty {
            if fm.fileExists(atPath: path) {
                do {
                    try fm.removeItem(atPath: path)
                    deleted += 1
                } catch {
                }
            }
        }
        if let files = try? fm.contentsOfDirectory(atPath: StorageConfig.screenshotsDir) {
            for file in files {
                try? fm.removeItem(atPath: (StorageConfig.screenshotsDir as NSString).appendingPathComponent(file))
            }
        }
        statusMessage = tr("截图历史已清空", "Screenshot history cleared")
        loadStats()
    }

    private func withTimeout<T>(_ seconds: Int, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw TimeoutError(seconds: seconds)
            }
            guard let result = try await group.next() else { throw TimeoutError(seconds: seconds) }
            group.cancelAll()
            return result
        }
    }
}
