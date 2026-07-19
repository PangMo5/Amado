import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import WatchConnectivity

// MARK: - WatchLinkClient

/// The phone side of the watch relay. The Apple Watch can't reach the Mac
/// directly, so it forwards lock requests over WatchConnectivity; this client
/// activates the session, pushes the paired-Mac list to the watch, and surfaces
/// each request (with the requested Mac id) as an `AsyncStream`.
@DependencyClient
struct WatchLinkClient: Sendable {
  var activate: @Sendable () -> Void
  /// Push the current Mac list to the watch (latest-state, delivered when the
  /// watch next wakes).
  var syncMacs: @Sendable (_ macs: [WatchMac]) -> Void
  /// One element per lock request from the watch; the value is the requested
  /// Mac id (nil = "whichever", the phone picks the first).
  var lockRequests: @Sendable () -> AsyncStream<UUID?> = { AsyncStream { _ in } }
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
    var continuation: AsyncStream<UUID?>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
    super.init()
  }

  // MARK: Internal

  let stream: AsyncStream<UUID?>

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
    handle(message)
  }

  func session(
    _: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void,
  ) {
    handle(message)
    replyHandler(["ok": true])
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

  private let continuation: AsyncStream<UUID?>.Continuation
  private var pendingMacs: Data?

  private func updateMacs(_ data: Data, on session: WCSession) {
    do {
      try session.updateApplicationContext([WatchMessage.macsKey: data])
      logger.notice("updated watch application context")
    } catch {
      logger.error("application context update failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func handle(_ message: [String: Any]) {
    guard message[WatchMessage.actionKey] as? String == WatchMessage.lockAction else { return }
    let macID = (message[WatchMessage.macIDKey] as? String).flatMap(UUID.init)
    logger.log("watch requested lock (mac: \(macID?.uuidString ?? "first", privacy: .public))")
    continuation.yield(macID)
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado.iOS", category: "WatchLink")
