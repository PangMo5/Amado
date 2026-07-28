import Foundation

// MARK: - PairedDeviceName

public enum PairedDeviceName {
  /// A stable, non-editable label for an iPhone installation. The UUID remains
  /// the actual identity; the short suffix only makes lists easier to scan.
  public static func iPhone(_ id: UUID) -> String {
    "iPhone \(id.uuidString.prefix(6))"
  }
}

// MARK: - PairedClientIdentity

/// Stable identity for one iPhone installation. The identifier is shared by the
/// iPhone app and its extensions so the Mac can display and revoke that phone
/// independently from other paired phones.
public struct PairedClientIdentity: Codable, Equatable, Sendable, Identifiable {
  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }

  public let id: UUID
  public let name: String
}

// MARK: - PairedClient

/// One phone currently trusted by the Mac's pairing registry.
public struct PairedClient: Codable, Equatable, Sendable, Identifiable {
  public init(id: UUID, name: String, pairedAt: Date, lastSeenAt: Date) {
    self.id = id
    self.name = name
    self.pairedAt = pairedAt
    self.lastSeenAt = lastSeenAt
  }

  public let id: UUID
  public var name: String
  public let pairedAt: Date
  public var lastSeenAt: Date
}

// MARK: - PairedClientRegistry

/// Mac-side pairing state. Revoked identifiers are retained so a phone removed
/// on the Mac cannot silently add itself back during a background status check.
/// Scanning the pairing QR again sends an explicit hello and clears revocation.
public struct PairedClientRegistry: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(clients: [PairedClient] = [], revokedClientIDs: Set<UUID> = []) {
    self.clients = clients
    self.revokedClientIDs = revokedClientIDs
  }

  // MARK: Public

  public var clients: [PairedClient]
  public var revokedClientIDs: Set<UUID>

  public func isRevoked(_ id: UUID) -> Bool {
    revokedClientIDs.contains(id)
  }

  public mutating func register(
    _ identity: PairedClientIdentity,
    at now: Date,
    clearsRevocation: Bool,
  ) {
    if clearsRevocation {
      revokedClientIDs.remove(identity.id)
    }
    guard !revokedClientIDs.contains(identity.id) else { return }
    if let index = clients.firstIndex(where: { $0.id == identity.id }) {
      clients[index].name = identity.name
      clients[index].lastSeenAt = now
    } else {
      clients.append(
        PairedClient(
          id: identity.id,
          name: identity.name,
          pairedAt: now,
          lastSeenAt: now,
        )
      )
    }
    clients.sort {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public mutating func remove(_ id: UUID, revoke: Bool) {
    clients.removeAll { $0.id == id }
    if revoke {
      revokedClientIDs.insert(id)
    }
  }

}

// MARK: - PairedClientIdentityStore

/// Shared iPhone identity used by the app, widget, and Control Center extension.
public enum PairedClientIdentityStore {

  // MARK: Public

  public static func loadOrCreate() -> PairedClientIdentity {
    let defaults = UserDefaults(suiteName: AmadoService.appGroup) ?? .standard
    let id: UUID
    if
      let rawID = defaults.string(forKey: idKey),
      let storedID = UUID(uuidString: rawID)
    {
      id = storedID
    } else {
      id = UUID()
      defaults.set(id.uuidString, forKey: idKey)
    }
    return PairedClientIdentity(
      id: id,
      name: PairedDeviceName.iPhone(id),
    )
  }

  // MARK: Private

  private static let idKey = "paired-client-id"

}
