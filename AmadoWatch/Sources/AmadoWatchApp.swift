// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MPL-2.0

import ComposableArchitecture
import SwiftUI

@main
struct AmadoWatchApp: App {
  var body: some Scene {
    WindowGroup {
      WatchContentView(store: store)
    }
  }

  @State private var store = Store(initialState: WatchLockFeature.State()) {
    WatchLockFeature()
  }
}
