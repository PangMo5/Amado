import CryptoKit
import Foundation

/// The 256-bit secret shared between one client and the Mac agent, established
/// once at pairing time (in v1 the agent shows it as base64 / a QR code and the
/// client stores a copy). Every lock command is HMAC-signed with it, so a
/// device on the same Wi-Fi that has not been paired cannot forge a lock.
///
/// Stored as raw bytes (not `SymmetricKey`) so the type is trivially `Sendable`
/// and `Codable` for persistence; ``symmetricKey`` rebuilds the key on demand.
public struct PairingSecret: Equatable, Sendable, Codable {

  // MARK: Lifecycle

  public init(material: Data) {
    self.material = material
  }

  /// Reconstruct from the base64 form. Returns `nil` if the string is not valid
  /// base64 of exactly ``byteCount`` bytes.
  public init?(base64: String) {
    guard let data = Data(base64Encoded: base64), data.count == Self.byteCount else {
      return nil
    }
    material = data
  }

  // MARK: Public

  public static let byteCount = 32

  public let material: Data

  /// Base64 form for display, copy/paste, or QR-code pairing.
  public var base64: String {
    material.base64EncodedString()
  }

  /// A fresh, cryptographically random secret.
  public static func generate() -> Self {
    let key = SymmetricKey(size: .bits256)
    return Self(material: key.withUnsafeBytes { Data($0) })
  }

  // MARK: Internal

  var symmetricKey: SymmetricKey {
    SymmetricKey(data: material)
  }

}
