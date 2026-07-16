import AmadoKit
import Combine
import ComposableArchitecture
import Foundation

// MARK: - AppFeature

/// Root reducer for the Mac agent. Owns the listener lifecycle, the pairing
/// secret, replay-dedup state, and a small rolling activity log the menu shows.
@Reducer
struct AppFeature {

  // MARK: Internal

  @ObservableState
  struct State: Equatable {
    /// Non-sensitive, human-editable settings in `~/.config/amado/config.toml`
    /// (the tunnel host lives here). The pairing secret does NOT — it's an HMAC
    /// key kept in the Keychain.
    @Shared(.amadoConfig) var config
    /// Loaded from the Keychain on `.task`, held in memory for the QR / reveal
    /// UI. Empty until first launch generates one.
    var pairingSecretBase64 = ""
    var isListening = false
    var launchAtLogin = false
    var activity = [ActivityEntry]()
    /// Bounded FIFO of nonces seen inside the freshness window, for replay
    /// dedup. Small because stale commands are already rejected by `LockCodec`.
    var recentNonces = [UUID]()
    /// Set when a device completes pairing (a valid `.hello` arrives); the
    /// pairing window shows "✓ paired" and dismisses itself.
    var justPairedWith: String?
    /// Transient UI state for the Settings "Test connection" button.
    var remoteTesting = false
    var remoteTestMessage = ""
    /// Nearby BLE devices found while the proximity Settings pane is open.
    var proximityDevices = [DiscoveredDevice]()
    /// Live proximity status shown in the proximity Settings pane.
    var proximityStatus = ProximityStatus.disabled
    /// Signature of the proximity fields last pushed to the engine, so a config
    /// change (UI or external edit) re-issues monitor() at most once.
    var appliedProximityKey = ""

    var pairingSecret: PairingSecret? {
      PairingSecret(base64: pairingSecretBase64)
    }

    mutating func record(_ message: String, kind: ActivityEntry.Kind, id: UUID, at: Date) {
      activity.insert(ActivityEntry(id: id, at: at, message: message, kind: kind), at: 0)
      if activity.count > 50 {
        activity.removeLast(activity.count - 50)
      }
    }

    mutating func remember(_ nonce: UUID) {
      recentNonces.append(nonce)
      if recentNonces.count > 64 {
        recentNonces.removeFirst(recentNonces.count - 64)
      }
    }
  }

  enum Action {
    case task
    case listenerStarted
    case received(Data)
    case lockNowTapped
    case checkForUpdatesTapped
    case regenerateSecretTapped
    case pairingWindowClosed
    case launchAtLoginToggled(Bool)
    case remoteHostChanged(String)
    case testRemoteTapped
    case remoteTestFinished(String)
    case proximityAutoLockToggled(Bool)
    case proximityDeviceSelected(DiscoveredDevice)
    case proximityFarRSSIChanged(Int)
    case proximityGraceChanged(Double)
    case proximitySmoothingChanged(Int)
    case proximityScanToggled(Bool)
    case proximityDevicesUpdated([DiscoveredDevice])
    case proximityStatusChanged(ProximityStatus)
    case proximityConfigChanged(AmadoConfig)
    case proximityFarDetected
  }

  @Dependency(\.lockListener) var lockListener
  @Dependency(\.remoteListener) var remoteListener
  @Dependency(\.proximityLock) var proximityLock
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.secretStore) var secretStore
  @Dependency(\.screenLocker) var screenLocker
  @Dependency(\.updater) var updater
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        // Resolving the live updater starts Sparkle's automatic check schedule.
        updater.start()
        // Make sure ~/.config/amado/ exists before the first config write.
        try? ConfigLocation.ensureDirectoryExists()
        // The pairing secret lives in the Keychain (migrated once from the old
        // UserDefaults location). Mint one on first launch.
        state.pairingSecretBase64 = secretStore.load() ?? ""
        if state.pairingSecret == nil {
          let secret = PairingSecret.generate()
          state.pairingSecretBase64 = secret.base64
          secretStore.save(secret.base64)
        }
        // One-time migration of the tunnel host from the old UserDefaults key
        // into config.toml.
        if
          state.config.remoteHost.isEmpty,
          let legacyHost = UserDefaults.standard.string(forKey: "amado.remoteHost"),
          !legacyHost.isEmpty
        {
          state.$config.withLock { $0.remoteHost = legacyHost }
          UserDefaults.standard.removeObject(forKey: "amado.remoteHost")
        }
        state.launchAtLogin = loginItem.isEnabled()
        let cfg = state.config
        state.appliedProximityKey = proximityKey(cfg)
        let sharedConfig = state.$config
        // Listen on both transports; `.received` verifies + dedups by nonce, so
        // a command arriving via LAN *and* the tunnel locks at most once.
        return .merge(
          .run { send in
            try await lockListener.start()
            await send(.listenerStarted)
            for await data in lockListener.incoming() {
              await send(.received(data))
            }
          },
          .run { send in
            await remoteListener.start()
            for await data in remoteListener.incoming() {
              await send(.received(data))
            }
          },
          .run { send in
            if cfg.proximityAutoLock, let id = UUID(uuidString: cfg.proximityDeviceID) {
              proximityLock.monitor(id, cfg.proximityFarRSSI, cfg.proximityGraceSeconds, cfg.proximitySmoothing)
            }
            for await _ in proximityLock.farEvents() {
              await send(.proximityFarDetected)
            }
          },
          .run { send in
            for await proximityStatus in proximityLock.status() {
              await send(.proximityStatusChanged(proximityStatus))
            }
          },
          .run { send in
            // Re-issue monitor() when proximity config changes — from the
            // Settings UI or an external edit to config.toml (Sharing's file
            // watcher). Dedup lives in `.proximityConfigChanged`.
            for await newConfig in sharedConfig.publisher.values {
              await send(.proximityConfigChanged(newConfig))
            }
          },
          .run { send in
            // Subscribe ONCE for the app's lifetime. The Settings pane toggles
            // scanning on/off; it must not re-subscribe this single-consumer
            // stream (a second iteration yields nothing).
            for await devices in proximityLock.discovered() {
              await send(.proximityDevicesUpdated(devices))
            }
          },
        )

      case .listenerStarted:
        state.isListening = true
        return .none

      case .received(let data):
        guard let secret = state.pairingSecret else {
          state.record("Command ignored — not paired yet", kind: .rejected, id: uuid(), at: date.now)
          return .none
        }
        do {
          let command = try LockCodec.decode(data, secret: secret, now: date.now)
          guard !state.recentNonces.contains(command.nonce) else {
            state.record("Replay from \(command.origin) ignored", kind: .rejected, id: uuid(), at: date.now)
            return .none
          }
          state.remember(command.nonce)
          switch command.action {
          case .lock:
            state.record("Locked — command from \(command.origin)", kind: .locked, id: uuid(), at: date.now)
            return .run { _ in screenLocker.lock() }

          case .hello:
            // Pairing handshake — prove the device holds the secret, don't lock.
            state.justPairedWith = command.origin
            state.record("Paired with \(command.origin) ✓", kind: .paired, id: uuid(), at: date.now)
            return .none
          }
        } catch let error as LockCodecError {
          state.record("Rejected: \(error.reason)", kind: .rejected, id: uuid(), at: date.now)
          return .none
        } catch {
          state.record("Rejected: malformed command", kind: .rejected, id: uuid(), at: date.now)
          return .none
        }

      case .lockNowTapped:
        state.record("Locked — manual test", kind: .locked, id: uuid(), at: date.now)
        return .run { _ in screenLocker.lock() }

      case .checkForUpdatesTapped:
        updater.checkForUpdates()
        return .none

      case .regenerateSecretTapped:
        let secret = PairingSecret.generate()
        state.pairingSecretBase64 = secret.base64
        secretStore.save(secret.base64)
        state.recentNonces.removeAll()
        state.record("Pairing secret regenerated — re-pair your devices", kind: .rejected, id: uuid(), at: date.now)
        return .none

      case .pairingWindowClosed:
        state.justPairedWith = nil
        return .none

      case .launchAtLoginToggled(let enabled):
        state.launchAtLogin = enabled
        return .run { _ in loginItem.setEnabled(enabled) }

      case .remoteHostChanged(let host):
        state.$config.withLock { $0.remoteHost = host.trimmingCharacters(in: .whitespacesAndNewlines) }
        state.remoteTestMessage = ""
        return .none

      case .testRemoteTapped:
        let host = state.config.remoteHost
        guard !host.isEmpty, let url = URL(string: "https://\(host)") else {
          state.remoteTestMessage = "Enter a tunnel host first"
          return .none
        }
        state.remoteTesting = true
        state.remoteTestMessage = ""
        return .run { send in
          do {
            try await RemoteLockSender.probe(baseURL: url)
            await send(.remoteTestFinished("Reachable ✓ — remote lock is ready"))
          } catch {
            await send(.remoteTestFinished("Not reachable: \(error.localizedDescription)"))
          }
        }

      case .remoteTestFinished(let message):
        state.remoteTesting = false
        state.remoteTestMessage = message
        return .none

      case .proximityFarDetected:
        let name = state.config.proximityDeviceName.isEmpty ? "your iPhone" : state.config.proximityDeviceName
        state.record("Locked — \(name) left", kind: .locked, id: uuid(), at: date.now)
        return .run { _ in screenLocker.lock() }

      case .proximityStatusChanged(let proximityStatus):
        state.proximityStatus = proximityStatus
        return .none

      case .proximityAutoLockToggled(let on):
        // Persist only; the config observer re-issues monitor().
        state.$config.withLock { $0.proximityAutoLock = on }
        return .none

      case .proximityDeviceSelected(let device):
        state.$config.withLock {
          $0.proximityDeviceID = device.id.uuidString
          $0.proximityDeviceName = device.name
        }
        return .none

      case .proximityFarRSSIChanged(let rssi):
        state.$config.withLock { $0.proximityFarRSSI = rssi }
        return .none

      case .proximityGraceChanged(let seconds):
        state.$config.withLock { $0.proximityGraceSeconds = seconds }
        return .none

      case .proximitySmoothingChanged(let samples):
        state.$config.withLock { $0.proximitySmoothing = samples }
        return .none

      case .proximityConfigChanged(let newConfig):
        let key = proximityKey(newConfig)
        guard key != state.appliedProximityKey else { return .none }
        state.appliedProximityKey = key
        let id = newConfig.proximityAutoLock ? UUID(uuidString: newConfig.proximityDeviceID) : nil
        return .run { _ in
          proximityLock.monitor(id, newConfig.proximityFarRSSI, newConfig.proximityGraceSeconds, newConfig.proximitySmoothing)
        }

      case .proximityScanToggled(let on):
        // discovered() is subscribed once in `.task`; here we only start/stop the
        // scan and clear the list when the pane closes.
        if !on { state.proximityDevices = [] }
        return .run { _ in on ? proximityLock.startScanning() : proximityLock.stopScanning() }

      case .proximityDevicesUpdated(let devices):
        state.proximityDevices = devices
        return .none
      }
    }
  }

  // MARK: Private

  /// The proximity fields that, when changed, require re-issuing monitor().
  private func proximityKey(_ config: AmadoConfig) -> String {
    "\(config.proximityAutoLock)|\(config.proximityDeviceID)|\(config.proximityFarRSSI)|\(config.proximityGraceSeconds)|\(config.proximitySmoothing)"
  }

}

// MARK: - ActivityEntry

/// One line in the agent's rolling activity log.
struct ActivityEntry: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case locked
    case rejected
    case paired
  }

  let id: UUID
  let at: Date
  let message: String
  let kind: Kind
}

extension LockCodecError {
  fileprivate var reason: String {
    switch self {
    case .malformed: "malformed command"
    case .unsupportedVersion(let version): "unsupported protocol v\(version)"
    case .badSignature: "bad signature (wrong pairing secret?)"
    case .stale(let age): "stale by \(Int(age))s"
    }
  }
}
