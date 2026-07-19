import AmadoKit
import AppIntents
import Foundation

// MARK: - NoPairedMacError

/// No paired Mac was available to lock.
struct NoPairedMacError: Error, LocalizedError {
  var errorDescription: String? {
    "No paired Mac to lock. Pair one in the Amado app first."
  }
}

// MARK: - LockMacIntent

/// The action a widget button / Control Center control runs: lock a Mac. If
/// `macID` is set (widget configured with a target) it locks that one; otherwise
/// it uses the Control Center selection from the iPhone app. It runs in the
/// extension and reads the shared paired-Macs list without opening the app.
struct LockMacIntent: AppIntent {

  // MARK: Lifecycle

  init() { }

  init(macID: String?) {
    self.macID = macID
  }

  // MARK: Internal

  static let title: LocalizedStringResource = "Lock Mac"
  static let description = IntentDescription("Locks a paired Mac.")
  static let openAppWhenRun = false

  @Parameter(title: "Mac ID")
  var macID: String?

  func perform() async throws -> some IntentResult {
    let paired = PairedMacsStore.load()
    let selectedID = ControlCenterMacStore.load().macID
    let requestedID = macID.flatMap(UUID.init(uuidString:))
    let target = paired.first { $0.id == requestedID }
      ?? paired.first { $0.id == selectedID }
      ?? paired.first
    guard let target else { throw NoPairedMacError() }
    try await AmadoLockDispatcher.dispatch(.lock(origin: "Widget"), to: target)
    return .result()
  }

}

// MARK: - SelectMacIntent

/// Configuration for the home-screen widget: which Mac it locks.
struct SelectMacIntent: WidgetConfigurationIntent {
  init() { }

  static let title: LocalizedStringResource = "Choose Mac"
  static let description = IntentDescription("Pick which Mac this widget locks.")

  @Parameter(title: "Mac", optionsProvider: MacOptionsProvider())
  var mac: String?
}
