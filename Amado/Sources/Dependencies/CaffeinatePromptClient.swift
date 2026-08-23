// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros

// MARK: - CaffeinateKeepUnlockedChoice

enum CaffeinateKeepUnlockedChoice: Equatable, Sendable {
  case keepUnlocked(pausingAutoLock: Bool)
  case cancel
}

// MARK: - CaffeinatePromptClient

/// Presents outside the `MenuBarExtra` view hierarchy. A menu-style extra is
/// dismissed as soon as its Picker fires, so a SwiftUI dialog attached to that
/// transient view disappears before it can be shown.
@DependencyClient
struct CaffeinatePromptClient: Sendable {
  var confirmSafety: @Sendable () async -> Bool = { false }
  var chooseKeepUnlocked: @Sendable (
    _ includesOperationalSafety: Bool,
    _ autoLockEnabled: Bool,
  ) async -> CaffeinateKeepUnlockedChoice = { _, _ in .cancel }
  var confirmHelperRemoval: @Sendable () async -> Bool = { false }
}

// MARK: DependencyKey

extension CaffeinatePromptClient: DependencyKey {
  static let liveValue = CaffeinatePromptClient(
    confirmSafety: {
      await MainActor.run {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep this Mac awake with the lid closed?"
        alert.informativeText = """
          Caffeinate overrides normal lid-close sleep. Keeping a closed Mac running can increase heat and battery use. Never use it in a bag, bedding, or another enclosed space; place it on a hard, stable, well-ventilated surface.

          You are responsible for monitoring the Mac and disabling Caffeinate if conditions become unsafe. To the extent permitted by law, Amado and its contributors are not liable for resulting battery depletion, data loss, hardware damage, or injury.
          """
        alert.addButton(withTitle: "Enable Caffeinate")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)

        return alert.runModal() == .alertFirstButtonReturn
      }
    },
    chooseKeepUnlocked: { includesOperationalSafety, autoLockEnabled in
      await MainActor.run { () -> CaffeinateKeepUnlockedChoice in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
          localized: includesOperationalSafety
            ? "Keep this Mac awake and unlocked with the lid closed?"
            : "Keep this Mac unlocked while Caffeinate is active?",
          comment: "Confirmation title for Caffeinate's unlocked policy.",
        )
        var paragraphs = [String]()
        if includesOperationalSafety {
          paragraphs.append(
            String(
              localized: "Caffeinate overrides normal lid-close sleep. Keeping a closed Mac running can increase heat and battery use. Never use it in a bag, bedding, or another enclosed space; place it on a hard, stable, well-ventilated surface.",
              comment: "Operational safety warning when enabling Caffeinate's unlocked policy.",
            )
          )
        }
        paragraphs.append(
          String(
            localized: "Caffeinate will not lock the login session when the lid closes. Anyone with physical access—or access through remote-control software already enabled on this Mac—may be able to use your session and access its apps, files, accounts, and data. Use this policy only in a physically and remotely controlled environment.",
            comment: "Security consequences of choosing Caffeinate's unlocked policy.",
          )
        )
        if autoLockEnabled {
          paragraphs.append(
            String(
              localized: "Auto-lock is currently on. Keep it on for additional protection, or pause it while Caffeinate keeps the Mac unlocked. Pausing means Amado will not lock the Mac when your iPhone leaves.",
              comment: "Auto-lock choices within Caffeinate's unlocked-policy confirmation.",
            )
          )
        }
        if includesOperationalSafety {
          paragraphs.append(
            String(
              localized: "You are responsible for monitoring the Mac and disabling Caffeinate if conditions become unsafe. To the extent permitted by law, Amado and its contributors are not liable for resulting battery depletion, data loss, hardware damage, or injury.",
              comment: "Responsibility and liability warning when enabling Caffeinate.",
            )
          )
        }
        alert.informativeText = paragraphs.joined(separator: "\n\n")

        if autoLockEnabled {
          alert.addButton(
            withTitle: String(
              localized: "Keep Auto-lock On",
              comment: "Keeps Auto-lock enabled while confirming Caffeinate's unlocked policy.",
            )
          )
          alert.addButton(
            withTitle: String(
              localized: "Pause Auto-lock",
              comment: "Pauses Auto-lock while confirming Caffeinate's unlocked policy.",
            )
          )
        } else {
          alert.addButton(
            withTitle: String(
              localized: "Keep Unlocked",
              comment: "Confirms Caffeinate's unlocked login-session policy.",
            )
          )
        }
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
          return .keepUnlocked(pausingAutoLock: false)
        case .alertSecondButtonReturn where autoLockEnabled:
          return .keepUnlocked(pausingAutoLock: true)
        default: return .cancel
        }
      }
    },
    confirmHelperRemoval: {
      await MainActor.run {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the Power Helper?"
        alert.informativeText = """
          Caffeinate will be turned off and normal lid-close sleep will be restored. To use Caffeinate again, install the Power Helper explicitly from Caffeinate Settings; macOS may require administrator approval.
          """
        alert.addButton(withTitle: "Remove Power Helper")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)

        return alert.runModal() == .alertFirstButtonReturn
      }
    },
  )

  static let testValue = CaffeinatePromptClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var caffeinatePrompt: CaffeinatePromptClient {
    get { self[CaffeinatePromptClient.self] }
    set { self[CaffeinatePromptClient.self] = newValue }
  }
}
