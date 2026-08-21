// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MPL-2.0

import ComposableArchitecture
import SwiftUI

@main
struct AmadoiOSApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
    }
  }

  @State private var store = Store(initialState: LockSenderFeature.State()) {
    LockSenderFeature()
  }
}
