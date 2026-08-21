import AppKit
import Dependencies
import DependenciesMacros

// MARK: - CaffeinateAutoLockPauseChoice

enum CaffeinateAutoLockPauseChoice: Equatable, Sendable {
  case pause
  case keepAutoLockOn
  case cancel
}

// MARK: - CaffeinatePromptClient

/// Presents outside the `MenuBarExtra` view hierarchy. A menu-style extra is
/// dismissed as soon as its Picker fires, so a SwiftUI dialog attached to that
/// transient view disappears before it can be shown.
@DependencyClient
struct CaffeinatePromptClient: Sendable {
  var confirmSafety: @Sendable () async -> Bool = { false }
  var askAutoLockPause: @Sendable () async -> CaffeinateAutoLockPauseChoice = { .cancel }
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
    askAutoLockPause: {
      await MainActor.run { () -> CaffeinateAutoLockPauseChoice in
        let alert = NSAlert()
        alert.messageText = "Pause Auto-lock?"
        alert.informativeText =
          "Caffeinate can keep the login session unlocked, but proximity Auto-lock may still lock it when your iPhone leaves."
        alert.addButton(withTitle: "Pause while Caffeinate keeps unlocked")
        alert.addButton(withTitle: "Keep Auto-lock On")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .pause
        case .alertSecondButtonReturn: return .keepAutoLockOn
        default: return .cancel
        }
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
