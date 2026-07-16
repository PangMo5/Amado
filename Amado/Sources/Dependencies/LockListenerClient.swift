import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
@preconcurrency import Network
import OSLog

// MARK: - LockListenerClient

/// Listens on the fixed agent port (`AmadoService.defaultPort`) and surfaces
/// each incoming framed payload as an `AsyncStream<Data>`. It is deliberately
/// dumb about meaning: it hands raw wire bytes to the reducer, which owns
/// verification (HMAC via `LockCodec`) and replay dedup. Clients reach it by
/// `host:port` (Tailscale/VPN/LAN) — there is no Bonjour advertisement.
///
/// `@preconcurrency import Network` because Network.framework's handler
/// closures predate `Sendable`; everything here runs on a single serial queue,
/// and only `Sendable` values (the stream continuation and `Data`) escape.
@DependencyClient
struct LockListenerClient: Sendable {
  /// Start listening on the fixed agent port. Idempotent.
  var start: @Sendable () async throws -> Void
  var stop: @Sendable () async -> Void
  /// One element per received, newline-delimited payload (delimiter stripped).
  var incoming: @Sendable () -> AsyncStream<Data> = { AsyncStream { _ in } }
}

// MARK: DependencyKey

extension LockListenerClient: DependencyKey {
  static let liveValue: LockListenerClient = {
    let listener = LockListener()
    return LockListenerClient(
      start: { try await listener.start() },
      stop: { await listener.stop() },
      incoming: { listener.stream },
    )
  }()

  static let testValue = LockListenerClient(
    start: { },
    stop: { },
    incoming: { AsyncStream { _ in } },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var lockListener: LockListenerClient {
    get { self[LockListenerClient.self] }
    set { self[LockListenerClient.self] = newValue }
  }
}

// MARK: - LockListener

private actor LockListener {

  // MARK: Lifecycle

  init() {
    var continuation: AsyncStream<Data>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
  }

  // MARK: Internal

  let stream: AsyncStream<Data>

  func start() throws {
    guard listener == nil else { return }
    guard let port = NWEndpoint.Port(rawValue: UInt16(AmadoService.defaultPort)) else { return }
    let listener = try NWListener(using: .tcp, on: port)
    // Advertise over Bonjour under the Mac's name so clients auto-discover it on
    // the LAN (and match the right Mac when several are paired).
    listener.service = NWListener.Service(name: hostName, type: AmadoService.serviceType)

    let continuation = continuation
    listener.newConnectionHandler = { connection in
      connection.start(queue: Self.queue)
      Self.receive(connection, buffer: Data(), continuation: continuation)
    }
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        logger.log("listener ready, advertising \(AmadoService.serviceType, privacy: .public)")
      case .failed(let error):
        logger.error("listener failed: \(error.localizedDescription, privacy: .public)")
      default:
        break
      }
    }
    listener.start(queue: Self.queue)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
    logger.log("listener stopped")
  }

  // MARK: Private

  private static let queue = DispatchQueue(label: "dev.PangMo5.Amado.lock-listener")
  private static let maxFrame = 16 * 1024

  private let continuation: AsyncStream<Data>.Continuation
  private var listener: NWListener?

  /// Accumulate bytes on one connection until the frame delimiter, then yield
  /// the payload and close. One command per connection keeps the loop simple
  /// and bounds a misbehaving peer with `maxFrame`.
  private static func receive(
    _ connection: NWConnection,
    buffer: Data,
    continuation: AsyncStream<Data>.Continuation,
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maxFrame) { chunk, _, isComplete, error in
      var buffer = buffer
      if let chunk, !chunk.isEmpty {
        buffer.append(chunk)
        if let index = buffer.firstIndex(of: LockFraming.delimiter) {
          continuation.yield(Data(buffer[..<index]))
          connection.cancel()
          return
        }
        if buffer.count > maxFrame {
          logger.error("frame exceeded \(maxFrame) bytes — dropping connection")
          connection.cancel()
          return
        }
      }
      if isComplete || error != nil {
        connection.cancel()
        return
      }
      receive(connection, buffer: buffer, continuation: continuation)
    }
  }

}

private var hostName: String {
  Host.current().localizedName ?? "Mac"
}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "LockListener")
