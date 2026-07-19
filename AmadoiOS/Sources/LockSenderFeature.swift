import AmadoKit
import ComposableArchitecture
import Foundation
import UIKit
import WidgetKit

/// iPhone reducer: keep a list of paired Macs and lock a chosen one over the LAN
/// via `AmadoLockDispatcher`. Pairing (scan/paste) can happen anytime, even with
/// Macs already paired — it adds or updates one.
@Reducer
struct LockSenderFeature {

  // MARK: Internal

  @ObservableState
  struct State: Equatable {
    /// Shared with the widget/control extensions via the App Group container.
    @Shared(.fileStorage(PairedMacsStore.fileURL)) var pairedMacs = [PairedMac]()
    /// The Mac used by the static Control Center control.
    @Shared(.fileStorage(ControlCenterMacStore.fileURL)) var controlCenterSelection = ControlCenterMacSelection()
    var status = ""
    /// The Mac a send is in flight to, for a per-row spinner.
    var sendingMacID: UUID?
  }

  enum Action {
    case task
    case lockMac(UUID)
    case watchRequestedLock(macID: UUID?)
    case pasteTapped
    case scanned(String)
    case removeMac(UUID)
    case selectControlCenterMac(UUID)
    case lockResult(macID: UUID, message: String)
  }

  @Dependency(\.lockDispatcher) var lockDispatcher
  @Dependency(\.watchLink) var watchLink

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        normalizeControlCenterSelection(&state)
        let macs = watchMacs(state)
        return .run { send in
          watchLink.activate()
          watchLink.syncMacs(macs)
          for await macID in watchLink.lockRequests() {
            await send(.watchRequestedLock(macID: macID))
          }
        }

      case .lockMac(let id):
        guard let mac = state.pairedMacs.first(where: { $0.id == id }) else { return .none }
        return lock(&state, mac: mac)

      case .watchRequestedLock(let macID):
        // Lock the requested Mac, or the first paired one if unspecified.
        let mac = macID.flatMap { id in state.pairedMacs.first { $0.id == id } } ?? state.pairedMacs.first
        guard let mac else { return .none }
        return lock(&state, mac: mac)

      case .pasteTapped:
        guard let string = UIPasteboard.general.string else {
          state.status = "Clipboard is empty"
          return .none
        }
        return add(&state, from: string)

      case .scanned(let code):
        return add(&state, from: code)

      case .removeMac(let id):
        state.$pairedMacs.withLock { $0.removeAll { $0.id == id } }
        normalizeControlCenterSelection(&state)
        return syncEffect(state)

      case .selectControlCenterMac(let id):
        guard state.pairedMacs.contains(where: { $0.id == id }) else { return .none }
        state.$controlCenterSelection.withLock { $0.macID = id }
        return .none

      case .lockResult(let macID, let message):
        if state.sendingMacID == macID { state.sendingMacID = nil }
        state.status = message
        return .none
      }
    }
  }

  // MARK: Private

  private func watchMacs(_ state: State) -> [WatchMac] {
    state.pairedMacs.map { WatchMac(id: $0.id, name: $0.displayName) }
  }

  private func normalizeControlCenterSelection(_ state: inout State) {
    let selectedID = state.controlCenterSelection.macID
    guard !state.pairedMacs.contains(where: { $0.id == selectedID }) else { return }
    let fallbackID = state.pairedMacs.first?.id
    state.$controlCenterSelection.withLock { $0.macID = fallbackID }
  }

  /// Push the current Mac list to the watch and refresh the widgets so their
  /// Mac picker / content reflect the change immediately.
  private func syncEffect(_ state: State) -> Effect<Action> {
    let macs = watchMacs(state)
    return .run { _ in
      watchLink.syncMacs(macs)
      WidgetCenter.shared.reloadAllTimelines()
    }
  }

  private func lock(_ state: inout State, mac: PairedMac) -> Effect<Action> {
    state.sendingMacID = mac.id
    state.status = "Locking \(mac.displayName)…"
    return .run { send in
      do {
        try await lockDispatcher.lock(mac)
        await send(.lockResult(macID: mac.id, message: "Locked \(mac.displayName) ✓"))
      } catch {
        await send(.lockResult(macID: mac.id, message: "Failed: \(error.localizedDescription)"))
      }
    }
  }

  private func add(_ state: inout State, from string: String) -> Effect<Action> {
    guard let payload = PairingPayload.decode(string) else {
      state.status = "Not a valid Amado pairing code"
      return .none
    }
    let mac: PairedMac
    if let index = state.pairedMacs.firstIndex(where: { $0.secretBase64 == payload.secret }) {
      // Same Mac → re-pair: refresh its name in place.
      if !payload.name.isEmpty {
        state.$pairedMacs.withLock { $0[index].name = payload.name }
      }
      mac = state.pairedMacs[index]
    } else {
      let newMac = payload.pairedMac
      state.$pairedMacs.withLock { $0.append(newMac) }
      mac = newMac
    }
    normalizeControlCenterSelection(&state)
    state.status = "Paired with \(mac.displayName) ✓"
    // Say hello so the Mac shows the pairing landed, and push the updated list
    // to the watch.
    return .merge(
      .run { _ in try? await lockDispatcher.hello(mac) },
      syncEffect(state),
    )
  }

}
