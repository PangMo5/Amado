import Foundation
import Testing

@testable import AmadoKit

struct PairingSecretTests {
  @Test
  func `base 64 round trips`() throws {
    let secret = PairingSecret.generate()
    let restored = try #require(PairingSecret(base64: secret.base64))
    #expect(restored == secret)
  }

  @Test
  func `generates the expected byte count`() {
    #expect(PairingSecret.generate().material.count == PairingSecret.byteCount)
  }

  @Test
  func `rejects malformed base 64`() {
    #expect(PairingSecret(base64: "not base64 @@@") == nil)
  }

  @Test
  func `rejects wrong length`() {
    let tooShort = Data([1, 2, 3]).base64EncodedString()
    #expect(PairingSecret(base64: tooShort) == nil)
  }
}
