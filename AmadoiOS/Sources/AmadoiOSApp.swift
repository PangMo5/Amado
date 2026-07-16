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
