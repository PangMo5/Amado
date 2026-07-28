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
  func `round trips a stable paired client identity`() throws {
    let secret = PairingSecret.generate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let client = PairedClientIdentity(id: UUID(), name: "Shirou's iPhone")
    let command = LockCommand.status(origin: "iPhone", now: now, client: client)

    let wire = try LockCodec.encode(command, secret: secret)
    let decoded = try LockCodec.decode(wire, secret: secret, now: now)

    #expect(decoded.client == client)
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

  @Test(
    arguments: [
      (LockCommand.Action.lock, false, LockCommandResponse.Outcome.lockRequested),
      (.lock, true, .alreadyLocked),
      (.status, false, .unlocked),
      (.status, true, .locked),
      (.hello, false, .helloAccepted),
      (.unpair, false, .unpaired),
    ]
  )
  func `response outcome reflects the command and Mac state`(
    action: LockCommand.Action,
    isLocked: Bool,
    expected: LockCommandResponse.Outcome,
  ) {
    let command = LockCommand(
      action: action,
      origin: "iPhone",
      issuedAt: Date(timeIntervalSince1970: 1_000_000),
      nonce: UUID(),
    )

    let response = LockCommandResponse.responding(
      to: command,
      isLocked: isLocked,
      now: command.issuedAt,
    )

    #expect(response.commandNonce == command.nonce)
    #expect(response.outcome == expected)
  }

  @Test
  func `round trips an authenticated matching response`() throws {
    let secret = PairingSecret.generate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let command = LockCommand.status(origin: "iPhone", now: now, nonce: UUID())
    let identity = PairedMacIdentity(
      id: UUID(),
      name: "Studio Mac",
      serviceName: "PangMo5's MacBook Pro",
    )
    let response = LockCommandResponse.responding(
      to: command,
      isLocked: true,
      now: now,
      mac: identity,
    )

    let wire = try LockResponseCodec.encode(response, secret: secret)
    let decoded = try LockResponseCodec.decode(
      wire,
      secret: secret,
      matching: command,
      now: now,
    )

    #expect(decoded == response)
    #expect(decoded.mac == identity)
  }

  @Test
  func `pairing shares Mac identity without replacing the local record identity`() throws {
    let localRecordID = UUID()
    let macDeviceID = UUID()
    let payload = PairingPayload(
      name: "Studio Mac",
      secret: PairingSecret.generate().base64,
      remoteHost: nil,
      deviceID: macDeviceID,
      serviceName: "PangMo5's MacBook Pro",
    )
    var pairedMac = PairedMac(
      id: localRecordID,
      name: "Old Name",
      secretBase64: PairingSecret.generate().base64,
    )

    let receivedMac = payload.pairedMac
    pairedMac.apply(
      PairedMacIdentity(
        id: try #require(receivedMac.deviceID),
        name: receivedMac.name,
        serviceName: try #require(receivedMac.bonjourServiceName),
      )
    )

    #expect(pairedMac.id == localRecordID)
    #expect(pairedMac.deviceID == macDeviceID)
    #expect(pairedMac.name == "Studio Mac")
    #expect(pairedMac.bonjourServiceName == "PangMo5's MacBook Pro")
  }

  @Test
  func `round trips a confirmed lock transition response`() throws {
    let secret = PairingSecret.generate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let command = LockCommand.lock(origin: "Control Center", now: now, nonce: UUID())
    let response = LockCommandResponse(
      commandNonce: command.nonce,
      outcome: .locked,
      respondedAt: now.addingTimeInterval(1),
    )

    let wire = try LockResponseCodec.encode(response, secret: secret)
    let decoded = try LockResponseCodec.decode(
      wire,
      secret: secret,
      matching: command,
      now: response.respondedAt,
    )

    #expect(decoded == response)
  }

  @Test
  func `rejects a response for another command`() throws {
    let secret = PairingSecret.generate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let command = LockCommand.status(origin: "iPhone", now: now, nonce: UUID())
    let otherCommand = LockCommand.status(origin: "iPhone", now: now, nonce: UUID())
    let response = LockCommandResponse.responding(to: otherCommand, isLocked: true, now: now)
    let wire = try LockResponseCodec.encode(response, secret: secret)

    #expect(throws: LockCodecError.mismatchedRequestNonce) {
      try LockResponseCodec.decode(
        wire,
        secret: secret,
        matching: command,
        now: now,
      )
    }
  }

  @Test
  func `rejects a response signed by another secret`() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let command = LockCommand.status(origin: "iPhone", now: now, nonce: UUID())
    let response = LockCommandResponse.responding(to: command, isLocked: true, now: now)
    let wire = try LockResponseCodec.encode(response, secret: .generate())

    #expect(throws: LockCodecError.badSignature) {
      try LockResponseCodec.decode(
        wire,
        secret: .generate(),
        matching: command,
        now: now,
      )
    }
  }
}
