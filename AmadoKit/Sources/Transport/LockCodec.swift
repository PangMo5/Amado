import CryptoKit
import Foundation

// MARK: - LockCodecError

/// Why a decode failed. `Equatable`/`Sendable` so tests and TCA reducers can
/// pattern-match on it.
public enum LockCodecError: Error, Equatable, Sendable {
  /// The bytes were not a well-formed envelope / command.
  case malformed
  /// Envelope protocol version the agent does not understand.
  case unsupportedVersion(Int)
  /// HMAC did not match — wrong secret, or a forged / tampered packet.
  case badSignature
  /// Command was issued too far from the agent's clock (replay / skew).
  case stale(age: TimeInterval)
}

// MARK: - LockCodec

/// Signs and verifies `LockCommand`s. Stateless and cross-platform: the phone
/// signs with `encode`, the Mac agent verifies with `decode`. Replay dedup by
/// `nonce` is the agent's job (it needs to remember recent nonces); everything
/// here is a pure function of its inputs.
public enum LockCodec {
  /// Sign `command` with `secret` and return the newline-free wire bytes.
  public static func encode(_ command: LockCommand, secret: PairingSecret) throws -> Data {
    let commandData = try canonicalEncoder.encode(command)
    let signature = HMAC<SHA256>.authenticationCode(
      for: commandData,
      using: secret.symmetricKey,
    )
    let envelope = LockEnvelope(
      version: AmadoService.protocolVersion,
      commandData: commandData,
      signature: Data(signature),
    )
    return try JSONEncoder().encode(envelope)
  }

  /// Verify and unwrap wire bytes. Checks, in order: envelope well-formedness,
  /// protocol version, HMAC, then freshness against `now`.
  public static func decode(
    _ data: Data,
    secret: PairingSecret,
    now: Date = Date(),
  ) throws -> LockCommand {
    guard let envelope = try? JSONDecoder().decode(LockEnvelope.self, from: data) else {
      throw LockCodecError.malformed
    }
    guard envelope.version == AmadoService.protocolVersion else {
      throw LockCodecError.unsupportedVersion(envelope.version)
    }
    // Constant-time verification against the exact bytes that were signed.
    guard
      HMAC<SHA256>.isValidAuthenticationCode(
        envelope.signature,
        authenticating: envelope.commandData,
        using: secret.symmetricKey,
      )
    else {
      throw LockCodecError.badSignature
    }
    guard let command = try? canonicalDecoder.decode(LockCommand.self, from: envelope.commandData) else {
      throw LockCodecError.malformed
    }
    let age = now.timeIntervalSince(command.issuedAt)
    guard abs(age) <= LockCommand.freshnessWindow else {
      throw LockCodecError.stale(age: age)
    }
    return command
  }
}

/// A fixed encoder/decoder pair. `sortedKeys` + a stable date strategy make the
/// signed bytes deterministic for the sender; the receiver never re-encodes, so
/// this only has to be self-consistent.
private let canonicalEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  return encoder
}()

private let canonicalDecoder: JSONDecoder = {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return decoder
}()
