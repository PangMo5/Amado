import Foundation

// MARK: - PairedMacIdentity

/// Stable identity a Mac shares with its paired clients. The macOS-supplied
/// name may change, while the UUID continues to identify the same Mac.
public struct PairedMacIdentity: Codable, Equatable, Sendable, Identifiable {
  public init(id: UUID, name: String, serviceName: String) {
    self.id = id
    self.name = name
    self.serviceName = serviceName
  }

  public let id: UUID
  public let name: String
  /// Bonjour service name used only to locate this Mac on the LAN.
  public let serviceName: String
}

// MARK: - PairedMac

/// A Mac the phone has paired with. `id` is the phone-local record identity used
/// by widgets and selections; `deviceID` is the stable UUID shared by the Mac.
/// Keeping them separate lets existing widget configuration survive migrations
/// while names and pairing secrets change independently.
public struct PairedMac: Codable, Equatable, Sendable, Identifiable {

  // MARK: Lifecycle

  public init(
    id: UUID = UUID(),
    name: String,
    secretBase64: String,
    remoteHost: String? = nil,
    deviceID: UUID? = nil,
    serviceName: String? = nil,
  ) {
    self.id = id
    self.name = name
    self.secretBase64 = secretBase64
    self.remoteHost = remoteHost
    self.deviceID = deviceID
    self.serviceName = serviceName
  }

  // MARK: Public

  public let id: UUID
  public var name: String
  public var secretBase64: String
  /// Public host of the Mac's tunnel (e.g. `amado.example.com`), or `nil` when
  /// the Mac only accepts LAN locks. Mutable so re-pairing can update it.
  public var remoteHost: String?
  /// Stable UUID supplied by the Mac. Nil only for pairings created by older
  /// versions that have not been refreshed yet.
  public var deviceID: UUID?
  /// Bonjour service name is deliberately separate from the displayed name.
  public var serviceName: String?

  public var secret: PairingSecret? {
    PairingSecret(base64: secretBase64)
  }

  public var displayName: String {
    name.isEmpty ? "Mac" : name
  }

  public var bonjourServiceName: String? {
    let serviceName = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let serviceName, !serviceName.isEmpty {
      return serviceName
    }
    let legacyName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return legacyName.isEmpty ? nil : legacyName
  }

  /// HTTPS base URL of the Mac's tunnel, when set. The tunnel terminates TLS and
  /// forwards to the agent's local HTTP server.
  public var remoteURL: URL? {
    guard let remoteHost, !remoteHost.isEmpty else { return nil }
    return URL(string: "https://\(remoteHost)")
  }

  public mutating func apply(_ identity: PairedMacIdentity) {
    deviceID = identity.id
    name = identity.name
    serviceName = identity.serviceName
  }

}

// MARK: - PairingPayload

/// What a pairing QR / pasted string carries: the Mac's stable UUID,
/// macOS-supplied name, Bonjour service name, secret, and optional tunnel host.
/// New fields are optional so pairing codes from older releases remain
/// decodable.
public struct PairingPayload: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    name: String,
    secret: String,
    remoteHost: String? = nil,
    deviceID: UUID? = nil,
    serviceName: String? = nil,
  ) {
    self.name = name
    self.secret = secret
    self.remoteHost = remoteHost
    self.deviceID = deviceID
    self.serviceName = serviceName
  }

  // MARK: Public

  public let name: String
  public let secret: String
  public let remoteHost: String?
  public let deviceID: UUID?
  public let serviceName: String?

  public var pairedMac: PairedMac {
    PairedMac(
      name: name,
      secretBase64: secret,
      remoteHost: remoteHost,
      deviceID: deviceID,
      serviceName: serviceName,
    )
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
