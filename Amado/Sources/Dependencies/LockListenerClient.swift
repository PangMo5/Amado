import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
@preconcurrency import Network
import OSLog

// MARK: - LockListenerClient

/// Listens on the fixed agent port (`AmadoService.defaultPort`) and surfaces
/// each incoming framed payload to the reducer, which owns verification,
/// replay dedup, session-state inspection, and command effects. A verified
/// client keeps the connection open for the reducer's authenticated response.
///
/// `@preconcurrency import Network` because Network.framework's handler
/// closures predate `Sendable`; everything here runs on a single serial queue,
/// and only `Sendable` values (the stream continuation and `Data`) escape.
@DependencyClient
struct LockListenerClient: Sendable {
  /// Start listening on the fixed agent port. Idempotent.
  var start: @Sendable () async throws -> Void
  var stop: @Sendable () async -> Void
  /// One element per received, newline-delimited request.
  var incoming: @Sendable () -> AsyncStream<IncomingLockRequest> = { AsyncStream { _ in } }
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
    var continuation: AsyncStream<IncomingLockRequest>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
  }

  // MARK: Internal

  let stream: AsyncStream<IncomingLockRequest>

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

  private let continuation: AsyncStream<IncomingLockRequest>.Continuation
  private var listener: NWListener?

  /// Accumulate bytes on one connection until the frame delimiter, then yield
  /// one request. Valid authenticated commands keep the connection open until
  /// the reducer answers or the bounded response wait expires.
  private static func receive(
    _ connection: NWConnection,
    buffer: Data,
    continuation: AsyncStream<IncomingLockRequest>.Continuation,
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maxFrame) { chunk, _, isComplete, error in
      var buffer = buffer
      if let chunk, !chunk.isEmpty {
        buffer.append(chunk)
        if let index = buffer.firstIndex(of: LockFraming.delimiter) {
          let data = Data(buffer[..<index])
          let responseChannel = LockResponseChannel()
          continuation.yield(
            IncomingLockRequest(
              data: data,
              responseChannel: responseChannel,
            )
          )

          guard
            let secretBase64 = AmadoKeychain.loadSecret(),
            let secret = PairingSecret(base64: secretBase64),
            (try? LockCodec.decode(data, secret: secret)) != nil
          else {
            connection.cancel()
            return
          }

          Task {
            guard let response = await responseChannel.firstResponse() else {
              connection.cancel()
              return
            }
            connection.send(
              content: LockFraming.frame(response),
              completion: .contentProcessed { _ in connection.cancel() },
            )
          }
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
