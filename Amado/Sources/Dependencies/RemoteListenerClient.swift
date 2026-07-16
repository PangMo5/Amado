import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
import Hummingbird
import OSLog

// MARK: - RemoteListenerClient

/// The Mac agent's tunnel-facing intake. Runs a small HTTP server on
/// `127.0.0.1:AmadoService.localHTTPPort` that a user-run tunnel (Cloudflare
/// Tunnel / Tailscale Funnel / ngrok) forwards its public host to. `POST /lock`
/// and `POST /hello` carry the very same signed envelope the LAN path uses; the
/// handler verifies the HMAC (an unauthenticated request gets 401) then hands
/// the raw bytes to the reducer, which owns replay dedup and the actual lock —
/// identical to the LAN listener, so both transports share one code path.
@DependencyClient
struct RemoteListenerClient: Sendable {
  /// Start the HTTP server. Idempotent.
  var start: @Sendable () async -> Void
  var incoming: @Sendable () -> AsyncStream<Data> = { AsyncStream { _ in } }
}

// MARK: DependencyKey

extension RemoteListenerClient: DependencyKey {
  static let liveValue: RemoteListenerClient = {
    let listener = RemoteListener()
    return RemoteListenerClient(
      start: { await listener.start() },
      incoming: { listener.stream },
    )
  }()

  static let testValue = RemoteListenerClient(start: { }, incoming: { AsyncStream { _ in } })
  static let previewValue = testValue
}

extension DependencyValues {
  var remoteListener: RemoteListenerClient {
    get { self[RemoteListenerClient.self] }
    set { self[RemoteListenerClient.self] = newValue }
  }
}

// MARK: - RemoteListener

private actor RemoteListener {

  // MARK: Lifecycle

  init() {
    var continuation: AsyncStream<Data>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
  }

  // MARK: Internal

  let stream: AsyncStream<Data>

  func start() {
    guard task == nil else { return }
    let continuation = continuation
    let router = Router()
    // /lock and /hello take the identical signed envelope; the reducer tells
    // them apart by the command's action, so one handler serves both.
    for path in [AmadoService.lockPath, AmadoService.helloPath] {
      router.post(RouterPath(stringLiteral: path)) { request, _ -> HTTPResponse.Status in
        var request = request
        let buffer = try await request.collectBody(upTo: Self.maxBody)
        let body = Data(buffer: buffer)
        guard let secret = Self.currentSecret() else { return .serviceUnavailable }
        // Verify the HMAC here so an unauthenticated caller gets 401; the
        // reducer re-decodes for dedup + lock + logging.
        guard (try? LockCodec.decode(body, secret: secret)) != nil else { return .unauthorized }
        continuation.yield(body)
        return .ok
      }
    }
    // Unauthenticated connectivity probe for the "Test connection" button.
    router.get(RouterPath(stringLiteral: AmadoService.healthPath)) { _, _ -> HTTPResponse.Status in
      .ok
    }
    let app = Application(
      router: router,
      configuration: .init(address: .hostname("127.0.0.1", port: AmadoService.localHTTPPort)),
    )
    task = Task {
      do { try await app.runService() }
      catch { logger.error("http server stopped: \(error.localizedDescription, privacy: .public)") }
    }
    logger.log("remote http server on 127.0.0.1:\(AmadoService.localHTTPPort, privacy: .public)")
  }

  // MARK: Private

  private static let maxBody = 64 * 1024

  private let continuation: AsyncStream<Data>.Continuation
  private var task: Task<Void, Never>?

  private static func currentSecret() -> PairingSecret? {
    guard let base64 = AmadoKeychain.loadSecret() else { return nil }
    return PairingSecret(base64: base64)
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "RemoteListener")
