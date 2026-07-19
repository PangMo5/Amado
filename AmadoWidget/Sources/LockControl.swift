import AmadoKit
import SwiftUI
import WidgetKit

/// A Control Center / Lock Screen / Action Button control that locks the Mac
/// selected in the iPhone app.
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
