import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

// MARK: - AmadoApp

@main
struct AmadoApp: App {

  // MARK: Internal

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(store: store)
    } label: {
      // The label view is always mounted in the menu bar, so its `.task` is
      // where we start the listener at launch (the agent is `LSUIElement` and
      // has no window to hang a lifecycle on).
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.menu)

    // Opened on demand from the menu ("Show pairing code…").
    Window("Amado", id: "pairing") {
      PairingView(store: store)
        .regularWhileOpen()
    }
    .windowResizability(.contentSize)

    Window("Amado Settings", id: "settings") {
      SettingsView(store: store)
        .regularWhileOpen()
    }
    .windowResizability(.contentSize)
  }

  // MARK: Private

  @State private var store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

}

// MARK: - MenuBarLabel

private struct MenuBarLabel: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    // Open lock while the agent is up (the Mac is unlocked — you only see the
    // menu bar then); slashed lock while the listener is still starting.
    Image(systemSymbol: store.isListening ? .lockOpenFill : .lockSlashFill)
      .task { await store.send(.task).finish() }
  }
}

// MARK: - Regular-while-open

extension View {
  /// Promote the `LSUIElement` agent to a regular app (Dock icon, normal
  /// front-most focus, standard window chrome) while this window is open, and
  /// drop back to accessory once the last window closes. Mirrors Tatami.
  fileprivate func regularWhileOpen() -> some View {
    onAppear { WindowActivation.opened() }
      .onDisappear { WindowActivation.closed() }
  }
}

// MARK: - WindowActivation

/// Reference-counts open windows so several (pairing + settings) can be open at
/// once without one closing prematurely dropping the app back to accessory.
@MainActor
private enum WindowActivation {
  static var openCount = 0

  static func opened() {
    openCount += 1
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  static func closed() {
    openCount = max(0, openCount - 1)
    if openCount == 0 {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
