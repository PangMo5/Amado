import AmadoKit
import SwiftUI
import WidgetKit

// MARK: - LockControl

/// A Control Center / Lock Screen / Action Button control that locks the Mac
/// selected in the iPhone app.
struct LockControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(
      kind: AmadoService.lockControlKind,
      provider: LockControlValueProvider(),
    ) { feedback in
      ControlWidgetButton(action: LockMacIntent()) {
        Label("Lock Mac", systemImage: "lock.fill")
          .controlWidgetStatus(feedback?.statusText ?? "Ready to lock")
      } actionLabel: { isActive in
        if isActive {
          Text("Locking…")
        }
      }
    }
    .displayName("Lock Mac")
  }
}

// MARK: - LockControlValueProvider

private struct LockControlValueProvider: ControlValueProvider {
  var previewValue: LockActionFeedback? {
    nil
  }

  func currentValue() async -> LockActionFeedback? {
    let paired = PairedMacsStore.load()
    let selectedID = ControlCenterMacStore.load().macID
    let targetID = paired.first { $0.id == selectedID }?.id ?? paired.first?.id
    return LockActionFeedbackStore.load(surface: .control, macID: targetID)
  }
}
