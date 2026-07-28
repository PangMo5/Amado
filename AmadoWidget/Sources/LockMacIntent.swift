import AmadoKit
import AppIntents
import Foundation
import WidgetKit

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

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let paired = PairedMacsStore.load()
    let selectedID = ControlCenterMacStore.load().macID
    let requestedID = macID.flatMap(UUID.init(uuidString:))
    let surface: LockActionFeedback.Surface = requestedID == nil ? .control : .widget
    let target = paired.first { $0.id == requestedID }
      ?? paired.first { $0.id == selectedID }
      ?? paired.first

    guard let target else {
      let feedback = LockActionFeedback(
        surface: surface,
        macID: nil,
        macName: "Mac",
        result: .noPairedMac,
      )
      finish(feedback)
      return .result(dialog: "\(feedback.statusText)")
    }

    let feedback: LockActionFeedback
    do {
      let origin = surface == .control ? "Control Center" : "Widget"
      let response = try await AmadoLockDispatcher.dispatch(
        .lock(origin: origin, client: clientIdentity),
        to: target,
      )
      PairedMacsStore.updateIdentity(response.mac, for: target.id)
      if response.outcome == .notPaired {
        PairedMacsStore.remove(id: target.id)
      }
      feedback = .responding(to: response.outcome, surface: surface, mac: target)
    } catch {
      feedback = LockActionFeedback(
        surface: surface,
        macID: target.id,
        macName: target.displayName,
        result: .failed,
      )
    }
    finish(feedback)
    return .result(dialog: "\(feedback.statusText)")
  }

  // MARK: Private

  private func finish(_ feedback: LockActionFeedback) {
    LockActionFeedbackStore.save(feedback)
    switch feedback.surface {
    case .control:
      ControlCenter.shared.reloadControls(ofKind: AmadoService.lockControlKind)
    case .widget:
      WidgetCenter.shared.reloadTimelines(ofKind: AmadoService.lockWidgetKind)
    }
  }

}

// MARK: - RefreshMacStatusIntent

/// Refreshes the configured Home Screen widget with the Mac's current lock
/// state without opening the iPhone app.
struct RefreshMacStatusIntent: AppIntent {

  // MARK: Lifecycle

  init() { }

  init(macID: String?) {
    self.macID = macID
  }

  // MARK: Internal

  static let title: LocalizedStringResource = "Refresh Mac Status"
  static let description = IntentDescription("Refreshes a paired Mac's current lock status.")
  static let openAppWhenRun = false

  @Parameter(title: "Mac ID")
  var macID: String?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let requestedID = macID.flatMap(UUID.init(uuidString:))
    let target = PairedMacsStore.load().first { $0.id == requestedID }

    guard let target else {
      let feedback = LockActionFeedback(
        surface: .widget,
        macID: requestedID,
        macName: "Mac",
        result: .noPairedMac,
      )
      finish(feedback)
      return .result(dialog: "\(feedback.statusText)")
    }

    let feedback: LockActionFeedback
    do {
      let response = try await AmadoLockDispatcher.dispatch(
        .status(origin: "Widget", client: clientIdentity),
        to: target,
      )
      PairedMacsStore.updateIdentity(response.mac, for: target.id)
      if response.outcome == .notPaired {
        PairedMacsStore.remove(id: target.id)
      }
      feedback = .reflectingStatus(response.outcome, surface: .widget, mac: target)
    } catch {
      feedback = LockActionFeedback(
        surface: .widget,
        macID: target.id,
        macName: target.displayName,
        result: .statusUnavailable,
      )
    }
    finish(feedback)
    return .result(dialog: "\(feedback.statusText)")
  }

  // MARK: Private

  private func finish(_ feedback: LockActionFeedback) {
    LockActionFeedbackStore.save(feedback)
    WidgetCenter.shared.reloadTimelines(ofKind: AmadoService.lockWidgetKind)
  }

}

private let clientIdentity = PairedClientIdentityStore.loadOrCreate()

// MARK: - SelectMacIntent

/// Configuration for the home-screen widget: which Mac it locks.
struct SelectMacIntent: WidgetConfigurationIntent {
  init() { }

  static let title: LocalizedStringResource = "Choose Mac"
  static let description = IntentDescription("Pick which Mac this widget locks.")

  @Parameter(title: "Mac", optionsProvider: MacOptionsProvider())
  var mac: String?
}
