// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Current macOS login-session state, shared by command responses and
/// proximity locking so every feature uses the same definition of "locked."
enum MacSessionState {
  static func isLocked() -> Bool {
    guard
      let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
      let locked = dictionary["CGSSessionScreenIsLocked"] as? Int
    else { return false }
    return locked == 1
  }
}
