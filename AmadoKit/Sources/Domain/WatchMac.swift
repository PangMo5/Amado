import Foundation

// MARK: - WatchMac

/// The slice of a `PairedMac` the phone syncs to the watch: just id + name.
/// Deliberately no secret — the watch relays lock requests through the phone
/// (which holds the secrets and does the actual send), so the wrist never
/// carries key material.
public struct WatchMac: Codable, Sendable, Identifiable, Equatable {
  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }

  public let id: UUID
  public let name: String
}

// MARK: - WatchMessage

/// Keys for the WatchConnectivity payloads exchanged between phone and watch.
public enum WatchMessage {
  /// applicationContext key carrying JSON `[WatchMac]` (phone → watch).
  public static let macsKey = "macs"
  /// sendMessage keys for a lock request (watch → phone).
  public static let actionKey = "action"
  public static let lockAction = "lock"
  public static let macIDKey = "macID"
}
