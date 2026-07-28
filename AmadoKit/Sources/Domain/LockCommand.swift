import Foundation

/// A single instruction a client (iPhone / Apple Watch) sends to the Mac agent.
///
/// The command is deliberately tiny and self-describing: the agent logs
/// `origin`, uses `issuedAt` to reject stale packets, and remembers `nonce` to
/// reject replays. See `LockCodec` for how it is signed and framed.
public struct LockCommand: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    action: Action,
    origin: String,
    issuedAt: Date,
    nonce: UUID,
    client: PairedClientIdentity? = nil,
  ) {
    self.action = action
    self.origin = origin
    self.issuedAt = issuedAt
    self.nonce = nonce
    self.client = client
  }

  // MARK: Public

  public enum Action: String, Codable, Sendable {
    case lock
    /// A pairing handshake: the client proves it holds the secret so the agent
    /// can show "paired ✓". Carries no lock — the agent must NOT lock on this.
    case hello
    /// Read the Mac's current lock state without changing it.
    case status
    /// The phone removed this Mac and asks the Mac to drop its matching client
    /// record. It can pair again later with an explicit `.hello`.
    case unpair
  }

  /// Commands older than this (relative to the agent's clock) are rejected as
  /// stale. 30s tolerates clock skew and slow relays without leaving a wide
  /// replay window.
  public static let freshnessWindow: TimeInterval = 30

  public let action: Action
  /// Human-readable source, shown in the agent's activity log (e.g. "iPhone").
  public let origin: String
  /// When the client issued the command. The agent rejects anything older than
  /// ``freshnessWindow`` so a captured packet cannot be replayed indefinitely.
  public let issuedAt: Date
  /// Random per-command value. The agent remembers recently seen nonces and
  /// refuses duplicates, so a replay inside the freshness window still locks
  /// at most once.
  public let nonce: UUID
  /// Stable identity of the sending iPhone installation. Optional so protocol
  /// v1 clients remain decodable while they migrate on their next update.
  public let client: PairedClientIdentity?

  /// A `.lock` command stamped now. `now`/`nonce` are injectable for tests.
  public static func lock(
    origin: String,
    now: Date = Date(),
    nonce: UUID = UUID(),
    client: PairedClientIdentity? = nil,
  ) -> Self {
    Self(action: .lock, origin: origin, issuedAt: now, nonce: nonce, client: client)
  }

  /// A `.hello` pairing handshake stamped now.
  public static func hello(
    origin: String,
    now: Date = Date(),
    nonce: UUID = UUID(),
    client: PairedClientIdentity? = nil,
  ) -> Self {
    Self(action: .hello, origin: origin, issuedAt: now, nonce: nonce, client: client)
  }

  /// A `.status` request stamped now.
  public static func status(
    origin: String,
    now: Date = Date(),
    nonce: UUID = UUID(),
    client: PairedClientIdentity? = nil,
  ) -> Self {
    Self(action: .status, origin: origin, issuedAt: now, nonce: nonce, client: client)
  }

  /// An `.unpair` request stamped now.
  public static func unpair(
    origin: String,
    now: Date = Date(),
    nonce: UUID = UUID(),
    client: PairedClientIdentity,
  ) -> Self {
    Self(action: .unpair, origin: origin, issuedAt: now, nonce: nonce, client: client)
  }

}
