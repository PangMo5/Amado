import Foundation

/// Protocol-versioned HMAC envelope for a ``LockCommandResponse``.
///
/// Responses use their own envelope instead of overloading `LockEnvelope`'s
/// command payload, keeping request and response decoding unambiguous.
public struct LockResponseEnvelope: Codable, Equatable, Sendable {
  public init(version: Int, responseData: Data, signature: Data) {
    self.version = version
    self.responseData = responseData
    self.signature = signature
  }

  public let version: Int
  public let responseData: Data
  public let signature: Data
}
