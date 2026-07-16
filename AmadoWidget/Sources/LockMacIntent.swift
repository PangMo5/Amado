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
/// `mac` is set (widget configured with a target) it locks that one; otherwise
/// it locks the first paired Mac. Runs in the extension — reads the shared
/// paired-Macs list and dispatches directly, without opening the app.
struct LockMacIntent: AppIntent {

  // MARK: Lifecycle

  init() { }

  init(mac: MacEntity?) {
    self.mac = mac
  }

  // MARK: Internal

  static let title: LocalizedStringResource = "Lock Mac"
  static let description = IntentDescription("Locks a paired Mac.")
  static let openAppWhenRun = false

  @Parameter(title: "Mac")
  var mac: MacEntity?

  func perform() async throws -> some IntentResult {
    let paired = PairedMacsStore.load()
    let target = mac.flatMap { entity in paired.first { $0.id == entity.id } } ?? paired.first
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

  @Parameter(title: "Mac")
  var mac: MacEntity?
}
