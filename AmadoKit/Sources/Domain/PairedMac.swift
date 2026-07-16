import Foundation

// MARK: - PairedMac

/// A Mac the phone has paired with. Carries the Mac's name (shown in the picker
/// and used to match its Bonjour service when locking over the LAN), that Mac's
/// pairing secret, and — if the Mac has remote access set up — the public host
/// of its tunnel, so the phone can reach it off-network. The Mac side stays
/// single-secret; only the client fans out across Macs.
public struct PairedMac: Codable, Equatable, Sendable, Identifiable {

  // MARK: Lifecycle

  public init(id: UUID = UUID(), name: String, secretBase64: String, remoteHost: String? = nil) {
    self.id = id
    self.name = name
    self.secretBase64 = secretBase64
    self.remoteHost = remoteHost
  }

  // MARK: Public

  public let id: UUID
  public var name: String
  public let secretBase64: String
  /// Public host of the Mac's tunnel (e.g. `amado.example.com`), or `nil` when
  /// the Mac only accepts LAN locks. Mutable so re-pairing can update it.
  public var remoteHost: String?

  public var secret: PairingSecret? {
    PairingSecret(base64: secretBase64)
  }

  public var displayName: String {
    name.isEmpty ? "Mac" : name
  }

  /// HTTPS base URL of the Mac's tunnel, when set. The tunnel terminates TLS and
  /// forwards to the agent's local HTTP server.
  public var remoteURL: URL? {
    guard let remoteHost, !remoteHost.isEmpty else { return nil }
    return URL(string: "https://\(remoteHost)")
  }

}

// MARK: - PairingPayload

/// What a pairing QR / pasted string carries: the Mac's name, secret, and (when
/// remote access is enabled) its tunnel host. The client finds the Mac on the
/// LAN by Bonjour (matching the name) and signs commands with the secret; off
/// the LAN it POSTs to the tunnel host. Encoded as compact JSON; a bare base64
/// secret is also accepted (name/host blank).
public struct PairingPayload: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(name: String, secret: String, remoteHost: String? = nil) {
    self.name = name
    self.secret = secret
    self.remoteHost = remoteHost
  }

  // MARK: Public

  public let name: String
  public let secret: String
  public let remoteHost: String?

  public var pairedMac: PairedMac {
    PairedMac(name: name, secretBase64: secret, remoteHost: remoteHost)
  }

  /// Parse a scanned / pasted pairing code: the JSON form, or a bare base64
  /// secret (name/host left blank).
  public static func decode(_ string: String) -> PairingPayload? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if
      let data = trimmed.data(using: .utf8),
      let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
      PairingSecret(base64: payload.secret) != nil
    {
      return payload
    }
    if PairingSecret(base64: trimmed) != nil {
      return PairingPayload(name: "", secret: trimmed)
    }
    return nil
  }

  /// Compact JSON string to embed in the QR / copy to the clipboard.
  public func encoded() -> String {
    guard
      let data = try? JSONEncoder().encode(self),
      let json = String(data: data, encoding: .utf8)
    else { return secret }
    return json
  }

}
