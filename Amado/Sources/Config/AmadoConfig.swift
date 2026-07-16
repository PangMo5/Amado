import Foundation

/// Root of Amado's on-disk configuration, at `~/.config/amado/config.toml`
/// (or `$XDG_CONFIG_HOME/amado/`). Non-sensitive, human-editable settings live
/// here; the pairing secret is kept in the Keychain, not this file, since it's
/// an HMAC key. Observed in-memory via `@Shared(.amadoConfig)`, so edits made
/// outside the app (vim, dotfiles) are picked up by Sharing's file watcher.
struct AmadoConfig: Equatable, Sendable, Codable {

  // MARK: Lifecycle

  init(
    remoteHost: String = "",
    proximityAutoLock: Bool = false,
    proximityDeviceID: String = "",
    proximityDeviceName: String = "",
    proximityFarRSSI: Int = -56,
    proximityGraceSeconds: Double = 2,
    proximitySmoothing: Int = 3,
  ) {
    self.remoteHost = remoteHost
    self.proximityAutoLock = proximityAutoLock
    self.proximityDeviceID = proximityDeviceID
    self.proximityDeviceName = proximityDeviceName
    self.proximityFarRSSI = proximityFarRSSI
    self.proximityGraceSeconds = proximityGraceSeconds
    self.proximitySmoothing = proximitySmoothing
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A missing key is the normal partial/empty-config case → default. A key
    // that is present but wrong-typed fails the decode so fileStorage keeps the
    // last good config instead of silently resetting.
    remoteHost = container.contains(.remoteHost)
      ? try container.decode(String.self, forKey: .remoteHost)
      : ""
    proximityAutoLock = container.contains(.proximityAutoLock)
      ? try container.decode(Bool.self, forKey: .proximityAutoLock)
      : false
    proximityDeviceID = container.contains(.proximityDeviceID)
      ? try container.decode(String.self, forKey: .proximityDeviceID)
      : ""
    proximityDeviceName = container.contains(.proximityDeviceName)
      ? try container.decode(String.self, forKey: .proximityDeviceName)
      : ""
    proximityFarRSSI = container.contains(.proximityFarRSSI)
      ? try container.decode(Int.self, forKey: .proximityFarRSSI)
      : -56
    proximityGraceSeconds = container.contains(.proximityGraceSeconds)
      ? try container.decode(Double.self, forKey: .proximityGraceSeconds)
      : 2
    proximitySmoothing = container.contains(.proximitySmoothing)
      ? try container.decode(Int.self, forKey: .proximitySmoothing)
      : 3
  }

  // MARK: Internal

  /// Public host of the tunnel the user runs for remote lock (e.g.
  /// `amado.example.com`); empty means LAN-only.
  var remoteHost: String
  /// Lock this Mac when the selected nearby device (the owner's iPhone) walks
  /// out of Bluetooth range.
  var proximityAutoLock: Bool
  /// CoreBluetooth identifier (UUID string) of the device to sense; empty = none.
  var proximityDeviceID: String
  /// Cached display name of that device, for the Settings UI.
  var proximityDeviceName: String
  /// dBm at/below which (smoothed, sustained for the grace) the Mac counts as
  /// "left". Less negative = must be closer to stay unlocked.
  var proximityFarRSSI: Int
  /// Seconds the signal must stay below the threshold before locking.
  var proximityGraceSeconds: Double
  /// Number of recent RSSI samples averaged before the near/far decision.
  /// Smaller = snappier but noisier; larger = smoother but laggier.
  var proximitySmoothing: Int

  // MARK: Private

  private enum CodingKeys: String, CodingKey {
    case remoteHost = "remote_host"
    case proximityAutoLock = "proximity_auto_lock"
    case proximityDeviceID = "proximity_device_id"
    case proximityDeviceName = "proximity_device_name"
    case proximityFarRSSI = "proximity_far_rssi"
    case proximityGraceSeconds = "proximity_grace_seconds"
    case proximitySmoothing = "proximity_smoothing"
  }

}
