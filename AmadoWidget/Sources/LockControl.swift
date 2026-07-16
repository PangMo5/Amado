import AmadoKit
import SwiftUI
import WidgetKit

/// A Control Center / Lock Screen / Action Button control that locks the first
/// paired Mac in one tap (`LockMacIntent` with no target → first Mac).
struct LockControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "dev.PangMo5.Amado.LockControl") {
      ControlWidgetButton(action: LockMacIntent()) {
        Label("Lock Mac", systemImage: "lock.fill")
      }
    }
    .displayName("Lock Mac")
  }
}
