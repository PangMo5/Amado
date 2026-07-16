import Foundation

/// What actually travels on the wire: a protocol-versioned wrapper around the
/// *exact* canonical bytes of a `LockCommand` plus an HMAC over those bytes.
///
/// The command is carried as raw `commandData` rather than a nested object so
/// the receiver verifies the signature against the identical bytes it was
/// signed over — there is no re-encoding step that could canonicalize
/// differently and break verification. `Data` encodes as base64 in JSON, so an
/// envelope serializes to a single newline-free line, which is all the socket
/// framing (`LockFraming`) relies on.
public struct LockEnvelope: Codable, Equatable, Sendable {
  public init(version: Int, commandData: Data, signature: Data) {
    self.version = version
    self.commandData = commandData
    self.signature = signature
  }

  public let version: Int
  public let commandData: Data
  public let signature: Data
}
