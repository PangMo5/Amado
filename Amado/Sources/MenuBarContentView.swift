import AppKit
import ComposableArchitecture
import SwiftUI

// MARK: - MenuBarContentView

/// The menu shown when the menu-bar icon is clicked: status, a manual-lock test
/// button, pairing controls, and the recent activity log.
struct MenuBarContentView: View {

  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    Text(store.isListening ? "Amado — listening" : "Amado — starting…")

    Button("Lock this Mac now") {
      store.send(.lockNowTapped)
    }

    Divider()

    OpenWindowButton(id: "pairing", title: "Show pairing code…")
    OpenWindowButton(id: "settings", title: "Settings…", shortcut: ",")
    Button("Check for Updates…") {
      store.send(.checkForUpdatesTapped)
    }

    Divider()

    if store.activity.isEmpty {
      Text("No activity yet")
    } else {
      Section("Recent") {
        ForEach(Array(store.activity.prefix(8))) { entry in
          Text(entry.message)
        }
      }
    }

    Divider()

    Button("Quit Amado") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

}

// MARK: - OpenWindowButton

/// Opens one of the app's windows from the menu. A dedicated view so it can read
/// the `openWindow` environment action (the agent is `LSUIElement`, so opening a
/// window also needs to activate the app to bring it to the front).
private struct OpenWindowButton: View {
  let id: String
  let title: String
  var shortcut: Character?

  var body: some View {
    Button(title) {
      openWindow(id: id)
      NSApp.activate(ignoringOtherApps: true)
    }
    .modifier(OptionalShortcut(shortcut: shortcut))
  }

  @Environment(\.openWindow) private var openWindow
}

// MARK: - OptionalShortcut

private struct OptionalShortcut: ViewModifier {
  let shortcut: Character?

  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(KeyEquivalent(shortcut))
    } else {
      content
    }
  }
}
