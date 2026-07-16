import Foundation
@preconcurrency import Network

// MARK: - LockSenderError

/// Why a LAN send failed. Public so the app / intents can surface it.
public enum LockSenderError: Error, LocalizedError, Equatable {
  case notPaired
  case noAgentFound
  case notReachable
  case offline
  case remoteUnreachable(host: String)
  case remoteRejected(status: Int)

  public var errorDescription: String? {
    switch self {
    case .notPaired: "Not paired with this Mac"
    case .noAgentFound: "That Mac isn't on this network"
    case .notReachable: "Not on the same network, and no remote access set up for this Mac"
    case .offline: "No internet connection"
    case .remoteUnreachable(let host):
      "Couldn't reach \(host) — check that its tunnel is running, then re-pair this Mac"
    case .remoteRejected(let status): "The Mac's tunnel rejected the command (HTTP \(status))"
    }
  }
}

// MARK: - LANLockSender

/// Sends a signed command to a specific Mac agent over the LAN: browse Bonjour
/// for `_amado._tcp`, pick the instance whose name matches the target (or the
/// first, when no name is given), open a TCP connection, and send one framed
/// command. `@preconcurrency import Network` because the handler closures
/// predate `Sendable`; all work runs on one serial queue.
public actor LANLockSender {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public func send(_ command: LockCommand, toMacNamed targetName: String?, secret: PairingSecret) async throws {
    let endpoint = try await resolveEndpoint(named: targetName)
    let payload = LockFraming.frame(try LockCodec.encode(command, secret: secret))
    try await deliver(payload, to: endpoint)
  }

  // MARK: Private

  private static let queue = DispatchQueue(label: "dev.PangMo5.Amado.lan-sender")
  /// Bonjour resolves in well under a second on the LAN, so keep this short:
  /// off-network it's just the wait before we report the Mac unreachable.
  private static let timeout: TimeInterval = 2

  private func resolveEndpoint(named targetName: String?) async throws -> NWEndpoint {
    try await withCheckedThrowingContinuation { continuation in
      let box = ContinuationBox(continuation)
      let browser = NWBrowser(
        for: .bonjour(type: AmadoService.serviceType, domain: nil),
        using: NWParameters(),
      )
      browser.browseResultsChangedHandler = { results, _ in
        let match = results.first { result in
          guard let targetName, !targetName.isEmpty else { return true }
          if case .service(let name, _, _, _) = result.endpoint {
            return name == targetName
          }
          return false
        }
        guard let endpoint = match?.endpoint else { return }
        browser.cancel()
        box.resume(returning: endpoint)
      }
      browser.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          browser.cancel()
          box.resume(throwing: error)
        }
      }
      browser.start(queue: Self.queue)
      Self.queue.asyncAfter(deadline: .now() + Self.timeout) {
        browser.cancel()
        box.resume(throwing: LockSenderError.noAgentFound)
      }
    }
  }

  private func deliver(_ payload: Data, to endpoint: NWEndpoint) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let box = ContinuationBox(continuation)
      let connection = NWConnection(to: endpoint, using: .tcp)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          connection.send(content: payload, completion: .contentProcessed { error in
            if let error {
              box.resume(throwing: error)
            } else {
              box.resume(returning: ())
            }
            connection.cancel()
          })

        case .failed(let error):
          box.resume(throwing: error)
          connection.cancel()

        default:
          break
        }
      }
      connection.start(queue: Self.queue)
      Self.queue.asyncAfter(deadline: .now() + Self.timeout) {
        box.resume(throwing: LockSenderError.noAgentFound)
        connection.cancel()
      }
    }
  }

}
