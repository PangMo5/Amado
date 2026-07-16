import Foundation
import Testing

@testable import AmadoKit

struct LockCodecTests {
  @Test
  func `round trips A valid command`() throws {
    let secret = PairingSecret.generate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let command = LockCommand.lock(origin: "iPhone", now: now, nonce: UUID())

    let wire = try LockCodec.encode(command, secret: secret)
    let decoded = try LockCodec.decode(wire, secret: secret, now: now)

    #expect(decoded == command)
  }

  @Test
  func `rejects wrong secret`() throws {
    let wire = try LockCodec.encode(.lock(origin: "iPhone"), secret: .generate())

    #expect(throws: LockCodecError.badSignature) {
      try LockCodec.decode(wire, secret: .generate(), now: Date())
    }
  }

  @Test
  func `rejects stale command`() throws {
    let secret = PairingSecret.generate()
    let issued = Date(timeIntervalSince1970: 1_000_000)
    let wire = try LockCodec.encode(.lock(origin: "iPhone", now: issued, nonce: UUID()), secret: secret)

    let error = #expect(throws: LockCodecError.self) {
      try LockCodec.decode(wire, secret: secret, now: issued.addingTimeInterval(120))
    }
    guard case .stale = error else {
      Issue.record("expected .stale, got \(String(describing: error))")
      return
    }
  }

  @Test
  func `rejects tampered payload`() throws {
    let secret = PairingSecret.generate()
    let wire = try LockCodec.encode(.lock(origin: "iPhone"), secret: secret)
    let envelope = try JSONDecoder().decode(LockEnvelope.self, from: wire)

    var mutated = envelope.commandData
    mutated[0] ^= 0xFF
    let tampered = LockEnvelope(version: envelope.version, commandData: mutated, signature: envelope.signature)
    let tamperedWire = try JSONEncoder().encode(tampered)

    #expect(throws: LockCodecError.badSignature) {
      try LockCodec.decode(tamperedWire, secret: secret, now: Date())
    }
  }

  @Test
  func `rejects unknown protocol version`() throws {
    let secret = PairingSecret.generate()
    let wire = try LockCodec.encode(.lock(origin: "iPhone"), secret: secret)
    let envelope = try JSONDecoder().decode(LockEnvelope.self, from: wire)

    // Same valid signature, bumped version: the version guard must fire first.
    let bumped = LockEnvelope(version: 999, commandData: envelope.commandData, signature: envelope.signature)
    let bumpedWire = try JSONEncoder().encode(bumped)

    #expect(throws: LockCodecError.unsupportedVersion(999)) {
      try LockCodec.decode(bumpedWire, secret: secret, now: Date())
    }
  }
}
