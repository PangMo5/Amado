import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import WatchConnectivity

// MARK: - PhoneLinkClient

/// The watch side of the relay: receives the paired-Mac list the phone syncs,
/// and forwards a lock request (with the chosen Mac id) to the phone, which
/// does the actual send. The watch never holds secrets or talks to the Mac
/// directly.
@DependencyClient
struct PhoneLinkClient: Sendable {
  var activate: @Sendable () -> Void
  /// The Mac list as the phone syncs it (latest wins).
  var macUpdates: @Sendable () -> AsyncStream<[WatchMac]> = { AsyncStream { _ in } }
  /// Ask the phone to lock `macID` (nil = first). Returns once acknowledged.
  var sendLock: @Sendable (_ macID: UUID?) async throws -> Void
}

// MARK: DependencyKey

extension PhoneLinkClient: DependencyKey {
  static let liveValue: PhoneLinkClient = {
    let link = WatchPhoneLink()
    return PhoneLinkClient(
      activate: { link.activate() },
      macUpdates: { link.stream },
      sendLock: { try await link.sendLock(macID: $0) },
    )
  }()

  static let testValue = PhoneLinkClient(activate: { }, macUpdates: { AsyncStream { _ in } }, sendLock: { _ in })
  static let previewValue = testValue
}

extension DependencyValues {
  var phoneLink: PhoneLinkClient {
    get { self[PhoneLinkClient.self] }
    set { self[PhoneLinkClient.self] = newValue }
  }
}

// MARK: - PhoneLinkError

enum PhoneLinkError: Error, LocalizedError, Equatable {
  case phoneUnreachable

  var errorDescription: String? {
    switch self {
    case .phoneUnreachable: "iPhone not reachable"
    }
  }
}

// MARK: - WatchPhoneLink

private final class WatchPhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {

  // MARK: Lifecycle

  override init() {
    var continuation: AsyncStream<[WatchMac]>.Continuation!
    stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    self.continuation = continuation
    super.init()
  }

  // MARK: Internal

  let stream: AsyncStream<[WatchMac]>

  func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  func sendLock(macID: UUID?) async throws {
    let session = WCSession.default
    guard session.isReachable else { throw PhoneLinkError.phoneUnreachable }
    var message: [String: Any] = [WatchMessage.actionKey: WatchMessage.lockAction]
    if let macID { message[WatchMessage.macIDKey] = macID.uuidString }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      session.sendMessage(
        message,
        replyHandler: { _ in continuation.resume() },
        errorHandler: { error in continuation.resume(throwing: error) },
      )
    }
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith _: WCSessionActivationState,
    error: (any Error)?,
  ) {
    if let error {
      logger.error("activation failed: \(error.localizedDescription, privacy: .public)")
    }
    emit(session.receivedApplicationContext)
  }

  func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    emit(applicationContext)
  }

  // MARK: Private

  private let continuation: AsyncStream<[WatchMac]>.Continuation

  private func emit(_ context: [String: Any]) {
    guard
      let data = context[WatchMessage.macsKey] as? Data,
      let macs = try? JSONDecoder().decode([WatchMac].self, from: data)
    else { return }
    continuation.yield(macs)
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado.watch", category: "PhoneLink")
