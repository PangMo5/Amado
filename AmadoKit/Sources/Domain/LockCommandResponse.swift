import Foundation

/// The authenticated result returned by the Mac for one command.
///
/// `commandNonce` binds the response to the exact request so a delayed or
/// replayed response cannot be mistaken for the current operation.
public struct LockCommandResponse: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    commandNonce: UUID,
    outcome: Outcome,
    respondedAt: Date,
    mac: PairedMacIdentity? = nil,
  ) {
    self.commandNonce = commandNonce
    self.outcome = outcome
    self.respondedAt = respondedAt
    self.mac = mac
  }

  // MARK: Public

  public enum Outcome: String, Codable, Equatable, Sendable {
    /// The Mac was unlocked when it accepted the lock command.
    case lockRequested
    /// The Mac was already locked, so no redundant lock was requested.
    case alreadyLocked
    /// The Mac is locked, either after a confirmed lock transition or a status
    /// query.
    case locked
    /// Result of an explicit status query.
    case unlocked
    /// The pairing handshake was accepted.
    case helloAccepted
    /// This phone was removed on the Mac and must scan the pairing code again.
    case notPaired
    /// The phone-initiated unpair request was accepted.
    case unpaired
  }

  public static let freshnessWindow = LockCommand.freshnessWindow

  public let commandNonce: UUID
  public let outcome: Outcome
  public let respondedAt: Date
  /// Stable Mac identity returned with authenticated responses. Optional so
  /// responses from older Mac releases remain decodable.
  public let mac: PairedMacIdentity?

  /// Builds the response for a verified command using the Mac's current state.
  public static func responding(
    to command: LockCommand,
    isLocked: Bool,
    now: Date = Date(),
    mac: PairedMacIdentity? = nil,
  ) -> Self {
    let outcome: Outcome =
      switch command.action {
      case .lock:
        isLocked ? .alreadyLocked : .lockRequested
      case .hello:
        .helloAccepted
      case .status:
        isLocked ? .locked : .unlocked
      case .unpair:
        .unpaired
      }
    return Self(
      commandNonce: command.nonce,
      outcome: outcome,
      respondedAt: now,
      mac: mac,
    )
  }

}
