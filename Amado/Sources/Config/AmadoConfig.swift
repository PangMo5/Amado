// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AmadoKit
import Foundation

// MARK: - ClosedLidMode

/// What closing the built-in display should do. A single mode avoids invalid
/// combinations such as "closed-lid mode off, but lock preference off."
enum ClosedLidMode: String, CaseIterable, Equatable, Sendable, Codable {
  case off
  case lock
  case unlocked

  // MARK: Internal

  enum AwakePolicy: Equatable, Hashable, Sendable {
    case lockOnClose
    case keepUnlocked

    var statusDescription: String {
      switch self {
      case .lockOnClose: "locks when the lid closes"
      case .keepUnlocked: "stays unlocked when the lid closes"
      }
    }
  }

  var awakePolicy: AwakePolicy? {
    switch self {
    case .off: nil
    case .lock: .lockOnClose
    case .unlocked: .keepUnlocked
    }
  }

  var keepsAwake: Bool {
    self != .off
  }

  var title: String {
    switch self {
    case .off: "Sleep normally"
    case .lock: "Stay awake and lock"
    case .unlocked: "Stay awake, keep unlocked"
    }
  }
}

// MARK: - AutoLockPause

enum AutoLockPause: Equatable, Sendable {
  case until(Date)
  case whileCaffeinating
}

// MARK: - AmadoConfig

/// Root of Amado's on-disk configuration, at `~/.config/amado/config.toml`
/// (or `$XDG_CONFIG_HOME/amado/`). Non-sensitive, human-editable settings live
/// here; the pairing secret is kept in the Keychain, not this file, since it's
/// an HMAC key. Observed in-memory via `@Shared(.amadoConfig)`, so edits made
/// outside the app (vim, dotfiles) are picked up by Sharing's file watcher.
struct AmadoConfig: Equatable, Sendable, Codable {

  // MARK: Lifecycle

  init(
    macID: String = "",
    remoteHost: String = "",
    closedLidMode: ClosedLidMode = .off,
    proximityAutoLock: Bool = false,
    caffeinatePausesAutoLock: Bool = false,
    proximityPauseUntil: Double? = nil,
    proximityDeviceID: String = "",
    proximityDeviceName: String = "",
    proximityMode: ProximityDetectionMode = .smart,
    proximitySensitivity: ProximitySensitivity = .balanced,
    proximityFarRSSI: Int = -56,
    proximityGraceSeconds: Double = 2,
    proximitySmoothing: Int = 3,
  ) {
    self.macID = macID
    self.remoteHost = remoteHost
    self.closedLidMode = closedLidMode
    self.proximityAutoLock = proximityAutoLock
    self.caffeinatePausesAutoLock = caffeinatePausesAutoLock
    self.proximityPauseUntil = proximityPauseUntil
    self.proximityDeviceID = proximityDeviceID
    self.proximityDeviceName = proximityDeviceName
    self.proximityMode = proximityMode
    self.proximitySensitivity = proximitySensitivity
    self.proximityFarRSSI = proximityFarRSSI
    self.proximityGraceSeconds = proximityGraceSeconds
    self.proximitySmoothing = proximitySmoothing
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A missing key is the normal partial/empty-config case → default. A key
    // that is present but wrong-typed fails the decode so fileStorage keeps the
    // last good config instead of silently resetting.
    macID = container.contains(.macID)
      ? try container.decode(String.self, forKey: .macID)
      : ""
    remoteHost = container.contains(.remoteHost)
      ? try container.decode(String.self, forKey: .remoteHost)
      : ""
    closedLidMode = container.contains(.closedLidMode)
      ? try container.decode(ClosedLidMode.self, forKey: .closedLidMode)
      : .off
    proximityAutoLock = container.contains(.proximityAutoLock)
      ? try container.decode(Bool.self, forKey: .proximityAutoLock)
      : false
    caffeinatePausesAutoLock = container.contains(.caffeinatePausesAutoLock)
      ? try container.decode(Bool.self, forKey: .caffeinatePausesAutoLock)
      : false
    proximityPauseUntil = container.contains(.proximityPauseUntil)
      ? try container.decode(Double.self, forKey: .proximityPauseUntil)
      : nil
    proximityDeviceID = container.contains(.proximityDeviceID)
      ? try container.decode(String.self, forKey: .proximityDeviceID)
      : ""
    proximityDeviceName = container.contains(.proximityDeviceName)
      ? try container.decode(String.self, forKey: .proximityDeviceName)
      : ""
    proximityMode = container.contains(.proximityMode)
      ? try container.decode(ProximityDetectionMode.self, forKey: .proximityMode)
      : .smart
    proximitySensitivity = container.contains(.proximitySensitivity)
      ? try container.decode(ProximitySensitivity.self, forKey: .proximitySensitivity)
      : .balanced
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

  /// Stable UUID this Mac shares with paired clients. Generated once on launch.
  var macID: String
  /// Public host of the tunnel the user runs for remote lock (e.g.
  /// `amado.example.com`); empty means LAN-only.
  var remoteHost: String
  /// Off, keep awake and lock, or keep awake while leaving the login session
  /// unlocked. The user-approved Power Helper applies the privileged modes.
  var closedLidMode: ClosedLidMode
  /// Lock this Mac when the selected nearby device (the owner's iPhone) walks
  /// out of Bluetooth range.
  var proximityAutoLock: Bool
  /// Suspend proximity locking whenever Caffeinate is configured to keep the
  /// login session unlocked. The pause ends with that Caffeinate policy.
  var caffeinatePausesAutoLock: Bool
  /// Unix timestamp through which proximity monitoring is suspended. Nil means
  /// auto-lock is not paused. Keeping the deadline on disk lets a pause survive
  /// app restarts without turning the underlying auto-lock preference off.
  var proximityPauseUntil: Double?
  /// CoreBluetooth identifier (UUID string) of the device to sense; empty = none.
  var proximityDeviceID: String
  /// Cached display name of that device, for the Settings UI.
  var proximityDeviceName: String
  /// Smart adaptive detection is the default; manual preserves direct control
  /// over the RSSI threshold, grace, and moving-average window.
  var proximityMode: ProximityDetectionMode
  /// Tradeoff between false-lock resistance and smart-mode reaction speed.
  var proximitySensitivity: ProximitySensitivity
  /// dBm at/below which (smoothed, sustained for the grace) the Mac counts as
  /// "left" in manual mode. Less negative = must be closer to stay unlocked.
  var proximityFarRSSI: Int
  /// Seconds the signal must stay below the threshold in manual mode.
  var proximityGraceSeconds: Double
  /// Number of recent RSSI samples averaged in manual mode.
  /// Smaller = snappier but noisier; larger = smoother but laggier.
  var proximitySmoothing: Int

  func activeProximityPauseUntil(at now: Date) -> Date? {
    guard let proximityPauseUntil else { return nil }
    let deadline = Date(timeIntervalSince1970: proximityPauseUntil)
    return deadline > now ? deadline : nil
  }

  func activeAutoLockPause(at now: Date) -> AutoLockPause? {
    if closedLidMode == .unlocked, caffeinatePausesAutoLock {
      return .whileCaffeinating
    }
    return activeProximityPauseUntil(at: now).map(AutoLockPause.until)
  }

  // MARK: Private

  private enum CodingKeys: String, CodingKey {
    case macID = "mac_id"
    case remoteHost = "remote_host"
    case closedLidMode = "caffeinate_mode"
    case proximityAutoLock = "proximity_auto_lock"
    case caffeinatePausesAutoLock = "caffeinate_pauses_auto_lock"
    case proximityPauseUntil = "proximity_pause_until"
    case proximityDeviceID = "proximity_device_id"
    case proximityDeviceName = "proximity_device_name"
    case proximityMode = "proximity_mode"
    case proximitySensitivity = "proximity_sensitivity"
    case proximityFarRSSI = "proximity_far_rssi"
    case proximityGraceSeconds = "proximity_grace_seconds"
    case proximitySmoothing = "proximity_smoothing"
  }

}
