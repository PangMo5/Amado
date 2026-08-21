import AppKit
import ComposableArchitecture
import SwiftUI

// MARK: - MenuBarContentView

/// The menu shown when the menu-bar icon is clicked: status, a manual-lock test
/// button, pairing controls, and the recent activity log.
struct MenuBarContentView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    Text(headline)

    if let issue = store.issues.first {
      Text(issue.detail)
      IssueRecoveryButton(issue: issue) { store.send(.issueRecoveryTapped(issue.kind)) }
      // More than one thing can be broken at once; the rest live in Settings
      // so the menu stays a menu.
      if store.issues.count > 1 {
        Text("\(store.issues.count - 1) more issue\(store.issues.count == 2 ? "" : "s") in Settings")
      }
      Divider()
    }

    Button("Lock this Mac now") {
      store.send(.lockNowTapped)
    }

    if store.config.proximityAutoLock, !store.config.proximityDeviceID.isEmpty {
      Menu("Pause Auto-lock") {
        if let deadline = store.proximityPauseUntil {
          Text("Paused until \(deadline.formatted(date: .abbreviated, time: .shortened))")
          Button("Resume Auto-lock") {
            store.send(.proximityPauseResumeTapped)
          }
        } else {
          ForEach(AppFeature.ProximityPausePreset.allCases, id: \.self) { preset in
            Button(preset.title) {
              store.send(.proximityPausePresetSelected(preset))
            }
          }
        }
      }
    }

    Divider()

    if store.pairedClients.isEmpty {
      OpenWindowButton(id: "pairing", title: "Show pairing code…")
    }
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

  // MARK: Private

  private var headline: String {
    switch store.health {
    case .impaired(let issue): "Amado — \(issue.title)"
    case .paused(let deadline):
      "Amado — auto-lock paused until \(deadline.formatted(date: .omitted, time: .shortened))"
    case .listening: "Amado — listening"
    case .starting: "Amado — starting…"
    }
  }

}

// MARK: - IssueRecoveryButton

/// The action offered next to the current issue. Retrying is the agent's job
/// and goes through the reducer; a System Settings pane is the user's and is
/// opened straight from the menu.
private struct IssueRecoveryButton: View {

  // MARK: Internal

  let issue: AgentIssue
  let onRetry: () -> Void

  var body: some View {
    switch issue.recovery {
    case .retry:
      Button("Try Again", action: onRetry)

    case .openSettings(let url):
      Button("Open Settings") { openURL(url) }

    case nil:
      EmptyView()
    }
  }

  // MARK: Private

  @Environment(\.openURL) private var openURL

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
