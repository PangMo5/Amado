import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation

// MARK: - LockDispatcherClient

/// Thin TCA wrapper over `AmadoLockDispatcher` (over the LAN, targeting one
/// Mac). Stamps commands with a fixed origin the Mac shows in its activity log.
@DependencyClient
struct LockDispatcherClient: Sendable {
  var clientIdentity: @Sendable () async -> PairedClientIdentity = {
    PairedClientIdentity(id: UUID(), name: "iPhone")
  }

  var lock: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse
  var lockFromWatch: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse
  var status: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse
  /// Pairing handshake so the Mac can show "paired ✓" — no lock.
  var hello: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse
  /// Tell the Mac that this iPhone intentionally removed it.
  var unpair: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse
}

// MARK: DependencyKey

extension LockDispatcherClient: DependencyKey {
  static let liveValue = LockDispatcherClient(
    clientIdentity: {
      loadClientIdentity()
    },
    lock: { mac in
      let identity = loadClientIdentity()
      return try await AmadoLockDispatcher.dispatch(
        .lock(origin: identity.name, client: identity),
        to: mac,
      )
    },
    lockFromWatch: { mac in
      let identity = loadClientIdentity()
      return try await AmadoLockDispatcher.dispatch(
        .lock(origin: "Apple Watch", client: identity),
        to: mac,
      )
    },
    status: { mac in
      let identity = loadClientIdentity()
      return try await AmadoLockDispatcher.dispatch(
        .status(origin: identity.name, client: identity),
        to: mac,
      )
    },
    hello: { mac in
      let identity = loadClientIdentity()
      return try await AmadoLockDispatcher.dispatch(
        .hello(origin: identity.name, client: identity),
        to: mac,
      )
    },
    unpair: { mac in
      let identity = loadClientIdentity()
      return try await AmadoLockDispatcher.dispatch(
        .unpair(origin: identity.name, client: identity),
        to: mac,
      )
    },
  )

  static let testValue = LockDispatcherClient(
    clientIdentity: { testClientIdentity },
    lock: { _ in testResponse(.lockRequested) },
    lockFromWatch: { _ in testResponse(.lockRequested) },
    status: { _ in testResponse(.unlocked) },
    hello: { _ in testResponse(.helloAccepted) },
    unpair: { _ in testResponse(.unpaired) },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var lockDispatcher: LockDispatcherClient {
    get { self[LockDispatcherClient.self] }
    set { self[LockDispatcherClient.self] = newValue }
  }
}

private func loadClientIdentity() -> PairedClientIdentity {
  PairedClientIdentityStore.loadOrCreate()
}

private let testClientIdentity = PairedClientIdentity(
  id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
  name: "iPhone 000000",
)

private func testResponse(_ outcome: LockCommandResponse.Outcome) -> LockCommandResponse {
  LockCommandResponse(
    commandNonce: UUID(),
    outcome: outcome,
    respondedAt: .distantPast,
  )
}
