import AmadoKit
import ComposableArchitecture
import Foundation
import UIKit
import WidgetKit

// MARK: - LockSenderFeature

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
    var macLockStatuses = [UUID: MacLockStatus]()
    /// The Mac a send is in flight to, for a per-row spinner.
    var sendingMacID: UUID?
  }

  enum Action {
    case task
    case lockMac(UUID)
    case watchRequestedLock(WatchLockRequest)
    case pasteTapped
    case scanned(String)
    case removeMac(UUID)
    case selectControlCenterMac(UUID)
    case refreshStatusesRequested
    case macStatusResponse(macID: UUID, LockOperationResult)
    case lockResponse(macID: UUID, LockOperationResult)
  }

  @Dependency(\.lockDispatcher) var lockDispatcher
  @Dependency(\.watchLink) var watchLink

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        normalizeControlCenterSelection(&state)
        let macs = watchMacs(state)
        let watchEffect = Effect<Action>.run { send in
          watchLink.activate()
          watchLink.syncMacs(macs)
          for await request in watchLink.lockRequests() {
            await send(.watchRequestedLock(request))
          }
        }
        return .merge(watchEffect, refreshStatuses(&state))

      case .lockMac(let id):
        guard let mac = state.pairedMacs.first(where: { $0.id == id }) else { return .none }
        return lock(&state, mac: mac)

      case .watchRequestedLock(let request):
        // Lock the requested Mac, or the first paired one if unspecified.
        let mac = request.macID.flatMap { id in state.pairedMacs.first { $0.id == id } } ?? state.pairedMacs.first
        guard let mac else {
          request.respond(withError: "No paired Mac")
          return .none
        }
        return .run { send in
          do {
            let outcome = try await lockDispatcher.lockFromWatch(mac)
            request.respond(with: outcome)
            await send(.lockResponse(macID: mac.id, .success(outcome)))
          } catch {
            let message = error.localizedDescription
            request.respond(withError: message)
            await send(.lockResponse(macID: mac.id, .failure(message)))
          }
        }

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
        state.macLockStatuses[id] = nil
        normalizeControlCenterSelection(&state)
        return syncEffect(state)

      case .selectControlCenterMac(let id):
        guard state.pairedMacs.contains(where: { $0.id == id }) else { return .none }
        state.$controlCenterSelection.withLock { $0.macID = id }
        return .none

      case .refreshStatusesRequested:
        return refreshStatuses(&state)

      case .macStatusResponse(let macID, let result):
        switch result {
        case .success(.locked),
             .success(.alreadyLocked):
          state.macLockStatuses[macID] = .locked
        case .success(.unlocked):
          state.macLockStatuses[macID] = .unlocked
        case .success,
             .failure:
          state.macLockStatuses[macID] = .unavailable
        }
        return .none

      case .lockResponse(let macID, let result):
        if state.sendingMacID == macID { state.sendingMacID = nil }
        let displayName = state.pairedMacs.first { $0.id == macID }?.displayName ?? "Mac"
        switch result {
        case .success(.alreadyLocked):
          state.macLockStatuses[macID] = .locked
          state.status = "\(displayName) is already locked"

        case .success(.lockRequested):
          state.macLockStatuses[macID] = .unavailable
          state.status = "Lock requested for \(displayName), but status confirmation was unavailable"

        case .success(.locked):
          state.macLockStatuses[macID] = .locked
          state.status = "Locked \(displayName) ✓"

        case .success:
          state.status = "Unexpected response from \(displayName)"

        case .failure(let message):
          state.macLockStatuses[macID] = .unavailable
          state.status = "Failed: \(message)"
        }
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
        let outcome = try await lockDispatcher.lock(mac)
        await send(.lockResponse(macID: mac.id, .success(outcome)))
      } catch {
        await send(.lockResponse(macID: mac.id, .failure(error.localizedDescription)))
      }
    }
  }

  private func refreshStatuses(_ state: inout State) -> Effect<Action> {
    let macs = state.pairedMacs
    for mac in macs {
      state.macLockStatuses[mac.id] = .checking
    }
    return .merge(
      macs.map { mac in
        .run { send in
          do {
            let outcome = try await lockDispatcher.status(mac)
            await send(.macStatusResponse(macID: mac.id, .success(outcome)))
          } catch {
            await send(.macStatusResponse(macID: mac.id, .failure(error.localizedDescription)))
          }
        }
      }
    )
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
    state.macLockStatuses[mac.id] = .checking
    // Say hello so the Mac shows the pairing landed, and push the updated list
    // to the watch.
    return .merge(
      .run { _ in try? await lockDispatcher.hello(mac) },
      .run { send in
        do {
          let outcome = try await lockDispatcher.status(mac)
          await send(.macStatusResponse(macID: mac.id, .success(outcome)))
        } catch {
          await send(.macStatusResponse(macID: mac.id, .failure(error.localizedDescription)))
        }
      },
      syncEffect(state),
    )
  }

}

// MARK: - MacLockStatus

enum MacLockStatus: Equatable, Sendable {
  case checking
  case locked
  case unlocked
  case unavailable
}

// MARK: - LockOperationResult

enum LockOperationResult: Equatable, Sendable {
  case success(LockCommandResponse.Outcome)
  case failure(String)
}
