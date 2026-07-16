import AmadoKit
import ComposableArchitecture
import Foundation

/// Apple Watch reducer: show the Macs the phone synced and relay a lock request
/// for the chosen one. All transport and crypto live downstream on the phone.
@Reducer
struct WatchLockFeature {
  @ObservableState
  struct State: Equatable {
    var macs = [WatchMac]()
    var status = ""
    var sendingMacID: UUID?
  }

  enum Action {
    case task
    case macsUpdated([WatchMac])
    case lockMac(UUID)
    case lockResult(macID: UUID, message: String)
  }

  @Dependency(\.phoneLink) var phoneLink

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          phoneLink.activate()
          for await macs in phoneLink.macUpdates() {
            await send(.macsUpdated(macs))
          }
        }

      case .macsUpdated(let macs):
        state.macs = macs
        return .none

      case .lockMac(let id):
        guard let mac = state.macs.first(where: { $0.id == id }) else { return .none }
        state.sendingMacID = id
        state.status = "Locking \(mac.name)…"
        return .run { send in
          do {
            try await phoneLink.sendLock(id)
            await send(.lockResult(macID: id, message: "Sent ✓"))
          } catch {
            await send(.lockResult(macID: id, message: error.localizedDescription))
          }
        }

      case .lockResult(let macID, let message):
        if state.sendingMacID == macID { state.sendingMacID = nil }
        state.status = message
        return .none
      }
    }
  }
}
