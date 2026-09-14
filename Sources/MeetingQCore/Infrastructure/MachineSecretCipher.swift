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

import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

public enum MachineSecretCipher {
    public static let prefix = "enc1:"

    private static func key() -> SymmetricKey {
        #if os(iOS)
        let uuidString = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        #else
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let uuidString: String = withUnsafeMutablePointer(to: &uuid) { ptr in
            gethostuuid(ptr, nil)
            return withUnsafeBytes(of: ptr.pointee) { Data($0) }
                .map { String(format: "%02x", $0) }
                .joined()
        }
        #endif
        let digest = SHA256.hash(data: Data(("CalledMe-secret-v1:" + uuidString).utf8))
        return SymmetricKey(data: Data(digest))
    }

    public static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty,
              let sealed = try? AES.GCM.seal(Data(plaintext.utf8), using: key()),
              let combined = sealed.combined else {
            return plaintext
        }
        return prefix + combined.base64EncodedString()
    }

    public static func decrypt(_ stored: String) -> String? {
        guard stored.hasPrefix(prefix) else { return stored }
        let payload = String(stored.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: payload),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(box, using: key()) else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }
}
