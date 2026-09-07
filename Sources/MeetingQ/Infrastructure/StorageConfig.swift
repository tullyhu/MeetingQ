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

import Foundation

public enum StorageConfig {
    private static let appSupport: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newDir = base.appendingPathComponent("MeetingQ", isDirectory: true).path
        let oldDir = base.appendingPathComponent("CalledMe", isDirectory: true).path
        let fm = FileManager.default
        if !fm.fileExists(atPath: newDir), fm.fileExists(atPath: oldDir) {
            try? fm.moveItem(atPath: oldDir, toPath: newDir)
        }
        renameLegacyDatabase(in: newDir)
        if let custom = try? String(contentsOfFile: (newDir as NSString).appendingPathComponent("storage_path.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty, custom != newDir {
            renameLegacyDatabase(in: custom)
        }
        return newDir
    }()

    private static func renameLegacyDatabase(in dir: String) {
        let fm = FileManager.default
        for suffix in ["db", "db-wal", "db-shm"] {
            let oldPath = (dir as NSString).appendingPathComponent("calledme.\(suffix)")
            let newPath = (dir as NSString).appendingPathComponent("meetingq.\(suffix)")
            if fm.fileExists(atPath: oldPath), !fm.fileExists(atPath: newPath) {
                try? fm.moveItem(atPath: oldPath, toPath: newPath)
            }
        }
    }

    public static var anchorDir: String { appSupport }
    private static var pointerFile: String { (appSupport as NSString).appendingPathComponent("storage_path.txt") }

    public static var storageDir: String {
        if let path = try? String(contentsOfFile: pointerFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           ensureAccessible(path) {
            return path
        }
        ensureAccessible(appSupport)
        return appSupport
    }

    public static var screenshotsDir: String {
        (storageDir as NSString).appendingPathComponent("Screenshots")
    }

    public static var databasePath: String {
        (storageDir as NSString).appendingPathComponent("meetingq.db")
    }

    public static func setStorageDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: anchorDir, withIntermediateDirectories: true)
        try path.write(toFile: pointerFile, atomically: true, encoding: .utf8)
    }

    public static func migrateData(from src: String, to dst: String) throws {
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        let fm = FileManager.default
        for file in try fm.contentsOfDirectory(atPath: src) where file.hasSuffix(".dat") || file.hasSuffix(".db") || file.hasSuffix(".db-wal") || file.hasSuffix(".db-shm") {
            let s = (src as NSString).appendingPathComponent(file)
            let d = (dst as NSString).appendingPathComponent(file)
            if fm.fileExists(atPath: d) { try fm.removeItem(atPath: d) }
            try fm.copyItem(atPath: s, toPath: d)
        }
    }

    @discardableResult
    public static func ensureAccessible(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let probe = (path as NSString).appendingPathComponent(".probe")
            FileManager.default.createFile(atPath: probe, contents: Data())
            try FileManager.default.removeItem(atPath: probe)
            return true
        } catch {
            return false
        }
    }
}
