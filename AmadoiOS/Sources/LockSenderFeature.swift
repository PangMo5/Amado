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
    /// Removed Macs whose unpair request has not been acknowledged yet.
    @Shared(.fileStorage(PendingMacUnpairsStore.fileURL)) var pendingUnpairs = [PairedMac]()
    /// The Mac used by the static Control Center control.
    @Shared(.fileStorage(ControlCenterMacStore.fileURL)) var controlCenterSelection = ControlCenterMacSelection()
    var clientID = ""
    var clientName = ""
    var status = ""
    var macLockStatuses = [UUID: MacLockStatus]()
    /// The Mac a send is in flight to, for a per-row spinner.
    var sendingMacID: UUID?
  }

  enum Action {
    case task
    case clientIdentityLoaded(PairedClientIdentity)
    case lockMac(UUID)
    case watchRequestedLock(WatchLockRequest)
    case pasteTapped
    case scanned(String)
    case removeMac(UUID)
    case unpairFinished(macID: UUID, succeeded: Bool)
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
        return .merge(
          watchEffect,
          .run { send in
            await send(.clientIdentityLoaded(lockDispatcher.clientIdentity()))
          },
          refreshStatuses(&state),
          retryPendingUnpairs(state),
        )

      case .clientIdentityLoaded(let identity):
        state.clientID = identity.id.uuidString
        state.clientName = identity.name
        return .none

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
            let response = try await lockDispatcher.lockFromWatch(mac)
            request.respond(with: response.outcome)
            await send(.lockResponse(macID: mac.id, .success(response)))
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
        let mac = state.pairedMacs.first { $0.id == id }
        state.$pairedMacs.withLock { $0.removeAll { $0.id == id } }
        if let mac {
          state.$pendingUnpairs.withLock {
            if !$0.contains(where: { $0.secretBase64 == mac.secretBase64 }) {
              $0.append(mac)
            }
          }
        }
        state.macLockStatuses[id] = nil
        normalizeControlCenterSelection(&state)
        return .merge(
          syncEffect(state),
          .run { send in
            guard let mac else { return }
            do {
              _ = try await lockDispatcher.unpair(mac)
              await send(.unpairFinished(macID: mac.id, succeeded: true))
            } catch {
              await send(.unpairFinished(macID: mac.id, succeeded: false))
            }
          },
        )

      case .unpairFinished(let macID, let succeeded):
        guard succeeded else { return .none }
        state.$pendingUnpairs.withLock { $0.removeAll { $0.id == macID } }
        return .none

      case .selectControlCenterMac(let id):
        guard state.pairedMacs.contains(where: { $0.id == id }) else { return .none }
        state.$controlCenterSelection.withLock { $0.macID = id }
        return .none

      case .refreshStatusesRequested:
        return refreshStatuses(&state)

      case .macStatusResponse(let macID, let result):
        switch result {
        case .success(let response):
          let identityChanged = apply(response.mac, to: macID, in: &state)
          switch response.outcome {
          case .locked,
               .alreadyLocked:
            state.macLockStatuses[macID] = .locked

          case .unlocked:
            state.macLockStatuses[macID] = .unlocked

          case .notPaired:
            let displayName = state.pairedMacs.first { $0.id == macID }?.displayName ?? "Mac"
            removeLocally(macID, from: &state)
            state.status = "\(displayName) was removed from the Mac. Pair it again to restore access."
            return syncEffect(state)

          case .helloAccepted,
               .lockRequested,
               .unpaired:
            state.macLockStatuses[macID] = .unavailable
          }
          return identityChanged ? syncEffect(state) : .none

        case .failure:
          state.macLockStatuses[macID] = .unavailable
          return .none
        }

      case .lockResponse(let macID, let result):
        if state.sendingMacID == macID { state.sendingMacID = nil }
        switch result {
        case .success(let response):
          let identityChanged = apply(response.mac, to: macID, in: &state)
          let displayName = state.pairedMacs.first { $0.id == macID }?.displayName ?? "Mac"
          switch response.outcome {
          case .alreadyLocked:
            state.macLockStatuses[macID] = .locked
            state.status = "\(displayName) is already locked"

          case .lockRequested:
            state.macLockStatuses[macID] = .unavailable
            state.status = "Lock requested for \(displayName), but status confirmation was unavailable"

          case .locked:
            state.macLockStatuses[macID] = .locked
            state.status = "Locked \(displayName) ✓"

          case .notPaired:
            removeLocally(macID, from: &state)
            state.status = "\(displayName) was removed from the Mac. Pair it again to restore access."
            return syncEffect(state)

          case .helloAccepted,
               .unlocked,
               .unpaired:
            state.status = "Unexpected response from \(displayName)"
          }
          return identityChanged ? syncEffect(state) : .none

        case .failure(let message):
          state.macLockStatuses[macID] = .unavailable
          state.status = "Failed: \(message)"
          return .none
        }
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

  private func removeLocally(_ id: UUID, from state: inout State) {
    state.$pairedMacs.withLock { $0.removeAll { $0.id == id } }
    state.macLockStatuses[id] = nil
    if state.sendingMacID == id {
      state.sendingMacID = nil
    }
    normalizeControlCenterSelection(&state)
  }

  @discardableResult
  private func apply(
    _ identity: PairedMacIdentity?,
    to localID: UUID,
    in state: inout State,
  ) -> Bool {
    guard
      let identity,
      let index = state.pairedMacs.firstIndex(where: { $0.id == localID })
    else {
      return false
    }
    let current = state.pairedMacs[index]
    guard
      current.deviceID != identity.id
      || current.name != identity.name
      || current.serviceName != identity.serviceName
    else {
      return false
    }
    state.$pairedMacs.withLock { $0[index].apply(identity) }
    return true
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
        let response = try await lockDispatcher.lock(mac)
        await send(.lockResponse(macID: mac.id, .success(response)))
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
            let response = try await lockDispatcher.status(mac)
            await send(.macStatusResponse(macID: mac.id, .success(response)))
          } catch {
            await send(.macStatusResponse(macID: mac.id, .failure(error.localizedDescription)))
          }
        }
      }
    )
  }

  private func retryPendingUnpairs(_ state: State) -> Effect<Action> {
    .merge(
      state.pendingUnpairs.map { mac in
        .run { send in
          do {
            _ = try await lockDispatcher.unpair(mac)
            await send(.unpairFinished(macID: mac.id, succeeded: true))
          } catch {
            await send(.unpairFinished(macID: mac.id, succeeded: false))
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
    state.$pendingUnpairs.withLock {
      $0.removeAll {
        $0.secretBase64 == payload.secret
          || (payload.deviceID != nil && $0.deviceID == payload.deviceID)
      }
    }
    let mac: PairedMac
    if
      let index = state.pairedMacs.firstIndex(where: {
        $0.secretBase64 == payload.secret
          || (payload.deviceID != nil && $0.deviceID == payload.deviceID)
      })
    {
      // Same Mac: retain the phone-local record ID so existing widgets and
      // selections remain valid while refreshing the shared identity.
      state.$pairedMacs.withLock {
        $0[index].secretBase64 = payload.secret
        $0[index].remoteHost = payload.remoteHost
        $0[index].deviceID = payload.deviceID ?? $0[index].deviceID
        $0[index].serviceName = payload.serviceName ?? $0[index].serviceName
        if !payload.name.isEmpty {
          $0[index].name = payload.name
        }
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
      .run { _ in _ = try? await lockDispatcher.hello(mac) },
      .run { send in
        do {
          let response = try await lockDispatcher.status(mac)
          await send(.macStatusResponse(macID: mac.id, .success(response)))
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
  case success(LockCommandResponse)
  case failure(String)
}
