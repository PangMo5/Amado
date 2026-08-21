import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
@preconcurrency import Network
import OSLog

// MARK: - LockListenerState

/// Whether the LAN listener is currently able to accept commands. The reducer
/// turns `unavailable` into a visible issue, because a listener that is down
/// looks exactly like an idle one from the menu bar.
enum LockListenerState: Equatable, Sendable {
  case ready
  case unavailable(reason: String)
}

// MARK: - LockListenerClient

/// Listens on the fixed agent port (`AmadoService.defaultPort`) and surfaces
/// each incoming framed payload to the reducer, which owns verification,
/// replay dedup, session-state inspection, and command effects. A verified
/// client keeps the connection open for the reducer's authenticated response.
///
/// `@preconcurrency import Network` because Network.framework's handler
/// closures predate `Sendable`; everything here runs on a single serial queue,
/// and only `Sendable` values (the stream continuations and `Data`) escape.
@DependencyClient
struct LockListenerClient: Sendable {
  /// Start listening on the fixed agent port, retrying until it succeeds.
  /// Idempotent.
  var start: @Sendable () async -> Void
  var stop: @Sendable () async -> Void
  /// One element per received, newline-delimited request.
  var incoming: @Sendable () -> AsyncStream<IncomingLockRequest> = { AsyncStream { _ in } }
  /// One element per availability change, so the agent can say why nothing is
  /// arriving instead of sitting silently on a dead socket.
  var state: @Sendable () -> AsyncStream<LockListenerState> = { AsyncStream { _ in } }
  /// Bring the listener up now, without waiting out the backoff.
  var retry: @Sendable () async -> Void
}

// MARK: DependencyKey

extension LockListenerClient: DependencyKey {
  static let liveValue: LockListenerClient = {
    let listener = LockListener()
    return LockListenerClient(
      start: { await listener.start() },
      stop: { await listener.stop() },
      incoming: { listener.stream },
      state: { listener.states },
      retry: { await listener.retryNow() },
    )
  }()

  static let testValue = LockListenerClient(
    start: { },
    stop: { },
    incoming: { AsyncStream { _ in } },
    state: { AsyncStream { _ in } },
    retry: { },
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
    var requests: AsyncStream<IncomingLockRequest>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { requests = $0 }
    continuation = requests

    var states: AsyncStream<LockListenerState>.Continuation!
    self.states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { states = $0 }
    stateContinuation = states
  }

  // MARK: Internal

  let stream: AsyncStream<IncomingLockRequest>
  let states: AsyncStream<LockListenerState>

  func start() {
    isStopped = false
    open()
  }

  func stop() {
    isStopped = true
    listener?.cancel()
    listener = nil
    logger.log("listener stopped")
  }

  /// Skip the remaining backoff. Used by the menu's "Try Again".
  func retryNow() {
    isStopped = false
    retryDelay = Self.initialRetryDelay
    open()
  }

  // MARK: Private

  private static let queue = DispatchQueue(label: "dev.PangMo5.Amado.lock-listener")
  private static let maxFrame = 16 * 1024
  private static let initialRetryDelay: TimeInterval = 1
  /// Long enough that a port held by another app is not hammered, short enough
  /// that recovery still feels automatic.
  private static let maxRetryDelay: TimeInterval = 30

  private let continuation: AsyncStream<IncomingLockRequest>.Continuation
  private let stateContinuation: AsyncStream<LockListenerState>.Continuation
  private var listener: NWListener?
  private var retryDelay = LockListener.initialRetryDelay

  /// Set by `stop()` so a scheduled retry does not resurrect the listener.
  private var isStopped = false

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

  private func open() {
    guard listener == nil, !isStopped else { return }
    guard let port = NWEndpoint.Port(rawValue: UInt16(AmadoService.defaultPort)) else {
      // A compile-time constant, so this can only mean the constant is wrong.
      stateContinuation.yield(.unavailable(reason: "Port \(AmadoService.defaultPort) is not usable"))
      return
    }

    let listener: NWListener
    do {
      listener = try NWListener(using: .tcp, on: port)
    } catch {
      fail(reason: error.localizedDescription)
      return
    }
    // Advertise over Bonjour under the Mac's name so clients auto-discover it on
    // the LAN (and match the right Mac when several are paired).
    listener.service = NWListener.Service(name: hostName, type: AmadoService.serviceType)

    let continuation = continuation
    listener.newConnectionHandler = { connection in
      connection.start(queue: Self.queue)
      Self.receive(connection, buffer: Data(), continuation: continuation)
    }
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        logger.log("listener ready, advertising \(AmadoService.serviceType, privacy: .public)")
        Task { await self?.becameReady() }

      case .failed(let error):
        logger.error("listener failed: \(error.localizedDescription, privacy: .public)")
        Task { await self?.fail(reason: error.localizedDescription) }

      default:
        break
      }
    }
    listener.start(queue: Self.queue)
    self.listener = listener
  }

  private func becameReady() {
    retryDelay = Self.initialRetryDelay
    stateContinuation.yield(.ready)
  }

  /// Drop the dead listener, say why, and line up another attempt. Without the
  /// retry a transient bind failure (the previous process still holding the
  /// port) would leave the agent permanently deaf.
  private func fail(reason: String) {
    listener?.cancel()
    listener = nil
    stateContinuation.yield(.unavailable(reason: reason))

    guard !isStopped else { return }
    let delay = retryDelay
    retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
    Self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      Task { await self?.open() }
    }
  }

}

private var hostName: String {
  Host.current().localizedName ?? "Mac"
}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "LockListener")
