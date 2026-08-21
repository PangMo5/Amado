// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
import Hummingbird
import OSLog

// MARK: - RemoteListenerState

/// Whether the tunnel-facing HTTP server is up. Separate from the LAN listener
/// because losing it only costs off-network access, not everything.
enum RemoteListenerState: Equatable, Sendable {
  case running
  case stopped(reason: String)
}

// MARK: - RemoteListenerClient

/// The Mac agent's tunnel-facing intake. Runs a small HTTP server on
/// `127.0.0.1:AmadoService.localHTTPPort` that a user-run tunnel (Cloudflare
/// Tunnel / Tailscale Funnel / ngrok) forwards its public host to. `POST /lock`
/// and `POST /hello` carry the very same signed envelope the LAN path uses; the
/// handler verifies the HMAC (an unauthenticated request gets 401) then hands
/// the request to the reducer, which owns replay dedup, session-state
/// inspection, and the actual lock. The HTTP response contains the reducer's
/// signed command result.
@DependencyClient
struct RemoteListenerClient: Sendable {
  /// Start the HTTP server, retrying if it stops. Idempotent.
  var start: @Sendable () async -> Void
  var incoming: @Sendable () -> AsyncStream<IncomingLockRequest> = { AsyncStream { _ in } }
  /// One element per availability change.
  var state: @Sendable () -> AsyncStream<RemoteListenerState> = { AsyncStream { _ in } }
  /// Bring the server up now, without waiting out the backoff.
  var retry: @Sendable () async -> Void
}

// MARK: DependencyKey

extension RemoteListenerClient: DependencyKey {
  static let liveValue: RemoteListenerClient = {
    let listener = RemoteListener()
    return RemoteListenerClient(
      start: { await listener.start() },
      incoming: { listener.stream },
      state: { listener.states },
      retry: { await listener.retryNow() },
    )
  }()

  static let testValue = RemoteListenerClient(
    start: { },
    incoming: { AsyncStream { _ in } },
    state: { AsyncStream { _ in } },
    retry: { },
  )
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
    var requests: AsyncStream<IncomingLockRequest>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { requests = $0 }
    continuation = requests

    var states: AsyncStream<RemoteListenerState>.Continuation!
    self.states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { states = $0 }
    stateContinuation = states
  }

  // MARK: Internal

  let stream: AsyncStream<IncomingLockRequest>
  let states: AsyncStream<RemoteListenerState>

  func start() {
    guard task == nil else { return }
    let continuation = continuation
    let router = Router()
    // All command paths take the same signed envelope and return a separately
    // signed response envelope.
    for path in [
      AmadoService.lockPath,
      AmadoService.helloPath,
      AmadoService.statusPath,
      AmadoService.unpairPath,
    ] {
      router.post(RouterPath(stringLiteral: path)) { request, _ -> Response in
        var request = request
        let buffer = try await request.collectBody(upTo: Self.maxBody)
        let body = Data(buffer: buffer)
        guard let secret = Self.currentSecret() else {
          return Response(status: .serviceUnavailable)
        }
        // Verify the HMAC here so an unauthenticated caller gets 401; the
        // reducer re-decodes for dedup + lock + logging.
        guard (try? LockCodec.decode(body, secret: secret)) != nil else {
          return Response(status: .unauthorized)
        }
        let responseChannel = LockResponseChannel()
        continuation.yield(
          IncomingLockRequest(
            data: body,
            responseChannel: responseChannel,
          )
        )
        guard let response = await responseChannel.firstResponse() else {
          return Response(status: .serviceUnavailable)
        }
        return Response(
          status: .ok,
          body: .init(byteBuffer: ByteBuffer(bytes: response)),
        )
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
    task = Task { [weak self] in
      do {
        try await app.runService()
        await self?.serviceEnded(reason: "The remote server stopped")
      } catch {
        logger.error("http server stopped: \(error.localizedDescription, privacy: .public)")
        await self?.serviceEnded(reason: error.localizedDescription)
      }
    }
    stateContinuation.yield(.running)
    logger.log("remote http server on 127.0.0.1:\(AmadoService.localHTTPPort, privacy: .public)")
  }

  /// Skip the remaining backoff. Used by the menu's "Try Again".
  func retryNow() {
    retryDelay = Self.initialRetryDelay
    start()
  }

  // MARK: Private

  private static let maxBody = 64 * 1024
  private static let initialRetryDelay: TimeInterval = 2
  private static let maxRetryDelay: TimeInterval = 60
  private static let retries = DispatchQueue(label: "dev.PangMo5.Amado.remote-listener-retry")

  private let continuation: AsyncStream<IncomingLockRequest>.Continuation
  private let stateContinuation: AsyncStream<RemoteListenerState>.Continuation
  private var task: Task<Void, Never>?
  private var retryDelay = RemoteListener.initialRetryDelay

  private static func currentSecret() -> PairingSecret? {
    guard let base64 = AmadoKeychain.loadSecret() else { return nil }
    return PairingSecret(base64: base64)
  }

  /// The server task finished, which for a long-running service always means
  /// something went wrong. Report it and line up another attempt.
  private func serviceEnded(reason: String) {
    task = nil
    stateContinuation.yield(.stopped(reason: reason))

    let delay = retryDelay
    retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
    Self.retries.asyncAfter(deadline: .now() + delay) { [weak self] in
      Task { await self?.start() }
    }
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "RemoteListener")
