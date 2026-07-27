import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation

// MARK: - LockDispatcherClient

/// Thin TCA wrapper over `AmadoLockDispatcher` (over the LAN, targeting one
/// Mac). Stamps commands with a fixed origin the Mac shows in its activity log.
@DependencyClient
struct LockDispatcherClient: Sendable {
  var lock: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse.Outcome
  var lockFromWatch: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse.Outcome
  var status: @Sendable (_ mac: PairedMac) async throws -> LockCommandResponse.Outcome
  /// Pairing handshake so the Mac can show "paired ✓" — no lock.
  var hello: @Sendable (_ mac: PairedMac) async throws -> Void
}

// MARK: DependencyKey

extension LockDispatcherClient: DependencyKey {
  static let liveValue = LockDispatcherClient(
    lock: { mac in
      try await AmadoLockDispatcher.dispatch(.lock(origin: deviceName), to: mac).outcome
    },
    lockFromWatch: { mac in
      try await AmadoLockDispatcher.dispatch(.lock(origin: "Apple Watch"), to: mac).outcome
    },
    status: { mac in
      try await AmadoLockDispatcher.dispatch(.status(origin: deviceName), to: mac).outcome
    },
    hello: { mac in
      _ = try await AmadoLockDispatcher.dispatch(.hello(origin: deviceName), to: mac)
    },
  )

  static let testValue = LockDispatcherClient(
    lock: { _ in .lockRequested },
    lockFromWatch: { _ in .lockRequested },
    status: { _ in .unlocked },
    hello: { _ in },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var lockDispatcher: LockDispatcherClient {
    get { self[LockDispatcherClient.self] }
    set { self[LockDispatcherClient.self] = newValue }
  }
}

private let deviceName = "iPhone"
