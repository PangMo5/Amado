import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import WatchConnectivity

// MARK: - WatchLockRequest

/// The phone side of the watch relay. The Apple Watch can't reach the Mac
/// directly, so it forwards lock requests over WatchConnectivity; this client
/// activates the session, pushes the paired-Mac list to the watch, and surfaces
/// each request with a one-shot reply channel as an `AsyncStream`.
struct WatchLockRequest: Sendable {
  init(macID: UUID?, reply: WatchLockReply) {
    self.macID = macID
    self.reply = reply
  }

  let macID: UUID?

  func respond(with outcome: LockCommandResponse.Outcome) {
    reply.respond([WatchMessage.outcomeKey: outcome.rawValue])
  }

  func respond(withError message: String) {
    reply.respond([WatchMessage.errorKey: message])
  }

  private let reply: WatchLockReply
}

// MARK: - WatchLockReply

final class WatchLockReply: @unchecked Sendable {

  // MARK: Lifecycle

  init(_ handler: (([String: Any]) -> Void)?) {
    self.handler = handler
  }

  // MARK: Internal

  func respond(_ message: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    handler?(message)
    handler = nil
  }

  // MARK: Private

  private let lock = NSLock()
  private var handler: (([String: Any]) -> Void)?

}

// MARK: - WatchLinkClient

@DependencyClient
struct WatchLinkClient: Sendable {
  var activate: @Sendable () -> Void
  /// Push the current Mac list to the watch (latest-state, delivered when the
  /// watch next wakes).
  var syncMacs: @Sendable (_ macs: [WatchMac]) -> Void
  /// One element per lock request from the watch, including its reply channel.
  var lockRequests: @Sendable () -> AsyncStream<WatchLockRequest> = { AsyncStream { _ in } }
}

// MARK: DependencyKey

extension WatchLinkClient: DependencyKey {
  static let liveValue: WatchLinkClient = {
    let link = PhoneWatchLink()
    return WatchLinkClient(
      activate: { link.activate() },
      syncMacs: { link.syncMacs($0) },
      lockRequests: { link.stream },
    )
  }()

  static let testValue = WatchLinkClient(
    activate: { },
    syncMacs: { _ in },
    lockRequests: { AsyncStream { _ in } },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var watchLink: WatchLinkClient {
    get { self[WatchLinkClient.self] }
    set { self[WatchLinkClient.self] = newValue }
  }
}

// MARK: - PhoneWatchLink

private final class PhoneWatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {

  // MARK: Lifecycle

  override init() {
    var continuation: AsyncStream<WatchLockRequest>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
    super.init()
  }

  // MARK: Internal

  let stream: AsyncStream<WatchLockRequest>

  func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  func syncMacs(_ macs: [WatchMac]) {
    guard WCSession.isSupported(), let data = try? JSONEncoder().encode(macs) else { return }
    // Retain the latest list for the next activation, then push if we can.
    pendingMacs = data
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    updateMacs(data, on: session)
  }

  func session(_: WCSession, didReceiveMessage message: [String: Any]) {
    handle(message, reply: WatchLockReply(nil))
  }

  func session(
    _: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void,
  ) {
    handle(message, reply: WatchLockReply(replyHandler))
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith state: WCSessionActivationState,
    error: (any Error)?,
  ) {
    if let error {
      logger.error("activation failed: \(error.localizedDescription, privacy: .public)")
    } else {
      logger.notice("activation completed with state \(state.rawValue, privacy: .public)")
    }
    // Flush the latest Mac list once the session is up.
    if state == .activated, let data = pendingMacs {
      updateMacs(data, on: session)
    }
  }

  func sessionDidBecomeInactive(_: WCSession) { }

  func sessionDidDeactivate(_ session: WCSession) {
    // Re-activate so a switched watch keeps working.
    session.activate()
  }

  // MARK: Private

  private let continuation: AsyncStream<WatchLockRequest>.Continuation
  private var pendingMacs: Data?

  private func updateMacs(_ data: Data, on session: WCSession) {
    do {
      try session.updateApplicationContext([WatchMessage.macsKey: data])
      logger.notice("updated watch application context")
    } catch {
      logger.error("application context update failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func handle(_ message: [String: Any], reply: WatchLockReply) {
    guard message[WatchMessage.actionKey] as? String == WatchMessage.lockAction else { return }
    let macID = (message[WatchMessage.macIDKey] as? String).flatMap(UUID.init)
    logger.log("watch requested lock (mac: \(macID?.uuidString ?? "first", privacy: .public))")
    continuation.yield(WatchLockRequest(macID: macID, reply: reply))
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado.iOS", category: "WatchLink")
