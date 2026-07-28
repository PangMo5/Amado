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

  enum ProximityPausePreset: TimeInterval, CaseIterable, Equatable, Sendable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400

    var title: String {
      switch self {
      case .fifteenMinutes: "15 minutes"
      case .thirtyMinutes: "30 minutes"
      case .oneHour: "1 hour"
      case .twoHours: "2 hours"
      case .fourHours: "4 hours"
      }
    }
  }

  @ObservableState
  struct State: Equatable {
    /// Non-sensitive, human-editable settings in `~/.config/amado/config.toml`
    /// (the tunnel host lives here). The pairing secret does NOT — it's an HMAC
    /// key kept in the Keychain.
    @Shared(.amadoConfig) var config
    /// Paired iPhones known to this Mac. Separate from config.toml because it
    /// is app-managed state rather than a hand-edited preference.
    @Shared(.pairedClientRegistry) var pairedClientRegistry
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

    var proximityPauseUntil: Date? {
      config.proximityPauseUntil.map(Date.init(timeIntervalSince1970:))
    }

    var pairedClients: [PairedClient] {
      pairedClientRegistry.clients
    }

    var macIdentity: PairedMacIdentity? {
      guard let id = UUID(uuidString: config.macID) else { return nil }
      return PairedMacIdentity(
        id: id,
        name: currentMacServiceName,
        serviceName: currentMacServiceName,
      )
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
    case received(IncomingLockRequest)
    case lockConfirmationFinished(origin: String, confirmed: Bool)
    case lockNowTapped
    case checkForUpdatesTapped
    case regenerateSecretTapped
    case pairingWindowClosed
    case removePairedClient(UUID)
    case launchAtLoginToggled(Bool)
    case remoteHostChanged(String)
    case testRemoteTapped
    case remoteTestFinished(String)
    case proximityAutoLockToggled(Bool)
    case proximityPausePresetSelected(ProximityPausePreset)
    case proximityPauseUntilSelected(Date)
    case proximityPauseResumeTapped
    case proximityPauseExpired(Date)
    case proximityDeviceSelected(DiscoveredDevice)
    case proximityModeChanged(ProximityDetectionMode)
    case proximitySensitivityChanged(ProximitySensitivity)
    case proximityRecalibrateTapped
    case proximityFarRSSIChanged(Int)
    case proximityGraceChanged(Double)
    case proximitySmoothingChanged(Int)
    case proximityScanToggled(Bool)
    case proximityDevicesUpdated([DiscoveredDevice])
    case proximityStatusChanged(ProximityStatus)
    case proximityConfigChanged(AmadoConfig)
    case proximityFarDetected(ProximityDecisionEngine.LockReason)
  }

  @Dependency(\.lockListener) var lockListener
  @Dependency(\.remoteListener) var remoteListener
  @Dependency(\.proximityLock) var proximityLock
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.secretStore) var secretStore
  @Dependency(\.screenLocker) var screenLocker
  @Dependency(\.updater) var updater
  @Dependency(\.continuousClock) var clock
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
        if UUID(uuidString: state.config.macID) == nil {
          state.$config.withLock {
            $0.macID = uuid().uuidString
          }
        }
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
        if state.config.proximityPauseUntil.map({ $0 <= date.now.timeIntervalSince1970 }) == true {
          state.$config.withLock { $0.proximityPauseUntil = nil }
        }
        let cfg = state.config
        state.appliedProximityKey = proximityKey(cfg)
        let sharedConfig = state.$config
        let proximityConfiguration = proximityMonitorConfiguration(cfg)
        // Listen on both transports; `.received` verifies + dedups by nonce, so
        // a command arriving via LAN *and* the tunnel locks at most once.
        return .merge(
          .run { send in
            try await lockListener.start()
            await send(.listenerStarted)
            for await request in lockListener.incoming() {
              await send(.received(request))
            }
          },
          .run { send in
            await remoteListener.start()
            for await request in remoteListener.incoming() {
              await send(.received(request))
            }
          },
          .run { send in
            proximityLock.monitor(proximityConfiguration)
            for await reason in proximityLock.farEvents() {
              await send(.proximityFarDetected(reason))
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
          proximityPauseTimer(for: cfg),
        )

      case .listenerStarted:
        state.isListening = true
        return .none

      case .received(let request):
        guard let secret = state.pairingSecret else {
          state.record("Command ignored — not paired yet", kind: .rejected, id: uuid(), at: date.now)
          return .none
        }
        do {
          let command = try LockCodec.decode(request.data, secret: secret, now: date.now)
          guard !state.recentNonces.contains(command.nonce) else {
            state.record("Replay from \(command.origin) ignored", kind: .rejected, id: uuid(), at: date.now)
            return .none
          }
          state.remember(command.nonce)
          let isLocked = screenLocker.isLocked()
          let macIdentity = state.macIdentity

          if let client = command.client {
            switch command.action {
            case .hello:
              state.$pairedClientRegistry.withLock {
                $0.register(client, at: date.now, clearsRevocation: true)
              }

            case .lock,
                 .status:
              guard !state.pairedClientRegistry.isRevoked(client.id) else {
                let response = LockCommandResponse(
                  commandNonce: command.nonce,
                  outcome: .notPaired,
                  respondedAt: date.now,
                  mac: macIdentity,
                )
                let responseData = try LockResponseCodec.encode(response, secret: secret)
                state.record(
                  "Rejected \(client.name), pairing was removed",
                  kind: .rejected,
                  id: uuid(),
                  at: date.now,
                )
                return .run { _ in request.respond(with: responseData) }
              }
              // An authenticated request from an older paired app migrates into
              // the registry on first contact. A locally revoked ID cannot take
              // this path and must scan the QR again.
              state.$pairedClientRegistry.withLock {
                $0.register(client, at: date.now, clearsRevocation: false)
              }

            case .unpair:
              state.$pairedClientRegistry.withLock {
                $0.remove(client.id, revoke: false)
              }
            }
          }

          switch command.action {
          case .lock:
            if isLocked {
              let response = LockCommandResponse(
                commandNonce: command.nonce,
                outcome: .alreadyLocked,
                respondedAt: date.now,
                mac: macIdentity,
              )
              let responseData = try LockResponseCodec.encode(response, secret: secret)
              state.record(
                "Already locked — command from \(command.origin)",
                kind: .locked,
                id: uuid(),
                at: date.now,
              )
              return .run { _ in request.respond(with: responseData) }
            }
            return .run { send in
              screenLocker.lock()
              var confirmed = screenLocker.isLocked()
              for _ in 0..<20 where !confirmed {
                try? await clock.sleep(for: .milliseconds(100))
                confirmed = screenLocker.isLocked()
              }
              let response = LockCommandResponse(
                commandNonce: command.nonce,
                outcome: confirmed ? .locked : .lockRequested,
                respondedAt: date.now,
                mac: macIdentity,
              )
              guard let responseData = try? LockResponseCodec.encode(response, secret: secret) else {
                return
              }
              request.respond(with: responseData)
              await send(.lockConfirmationFinished(origin: command.origin, confirmed: confirmed))
            }

          case .hello:
            // Pairing handshake — prove the device holds the secret, don't lock.
            let response = LockCommandResponse.responding(
              to: command,
              isLocked: isLocked,
              now: date.now,
              mac: macIdentity,
            )
            let responseData = try LockResponseCodec.encode(response, secret: secret)
            state.justPairedWith = command.origin
            state.record("Paired with \(command.origin) ✓", kind: .paired, id: uuid(), at: date.now)
            return .run { _ in request.respond(with: responseData) }

          case .status:
            let response = LockCommandResponse.responding(
              to: command,
              isLocked: isLocked,
              now: date.now,
              mac: macIdentity,
            )
            let responseData = try LockResponseCodec.encode(response, secret: secret)
            return .run { _ in request.respond(with: responseData) }

          case .unpair:
            let response = LockCommandResponse(
              commandNonce: command.nonce,
              outcome: .unpaired,
              respondedAt: date.now,
              mac: macIdentity,
            )
            let responseData = try LockResponseCodec.encode(response, secret: secret)
            if let client = command.client {
              state.record(
                "Unpaired \(client.name)",
                kind: .rejected,
                id: uuid(),
                at: date.now,
              )
            }
            return .run { _ in request.respond(with: responseData) }
          }
        } catch let error as LockCodecError {
          state.record("Rejected: \(error.reason)", kind: .rejected, id: uuid(), at: date.now)
          return .none
        } catch {
          state.record("Rejected: malformed command", kind: .rejected, id: uuid(), at: date.now)
          return .none
        }

      case .lockConfirmationFinished(let origin, let confirmed):
        state.record(
          confirmed
            ? "Locked — command from \(origin)"
            : "Lock requested but not confirmed — command from \(origin)",
          kind: .locked,
          id: uuid(),
          at: date.now,
        )
        return .none

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
        state.$pairedClientRegistry.withLock { $0 = PairedClientRegistry() }
        state.record("Pairing secret regenerated — re-pair your devices", kind: .rejected, id: uuid(), at: date.now)
        return .none

      case .pairingWindowClosed:
        state.justPairedWith = nil
        return .none

      case .removePairedClient(let id):
        guard let client = state.pairedClients.first(where: { $0.id == id }) else {
          return .none
        }
        state.$pairedClientRegistry.withLock {
          $0.remove(id, revoke: true)
        }
        state.record(
          "Removed pairing for \(client.name)",
          kind: .rejected,
          id: uuid(),
          at: date.now,
        )
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

      case .proximityFarDetected(let reason):
        guard
          state.config.proximityAutoLock,
          !state.config.proximityDeviceID.isEmpty,
          state.config.activeProximityPauseUntil(at: date.now) == nil
        else {
          return .none
        }
        let name = state.config.proximityDeviceName.isEmpty ? "your iPhone" : state.config.proximityDeviceName
        state.record(
          "Locked — \(name) left (\(reason.activityDescription))",
          kind: .locked,
          id: uuid(),
          at: date.now,
        )
        return .run { _ in screenLocker.lock() }

      case .proximityStatusChanged(let proximityStatus):
        state.proximityStatus = proximityStatus
        return .none

      case .proximityAutoLockToggled(let on):
        // Persist only; the config observer re-issues monitor().
        state.$config.withLock {
          $0.proximityAutoLock = on
          if !on {
            $0.proximityPauseUntil = nil
          }
        }
        return .none

      case .proximityPausePresetSelected(let preset):
        guard state.config.proximityAutoLock else { return .none }
        state.$config.withLock {
          $0.proximityPauseUntil = date.now.addingTimeInterval(preset.rawValue).timeIntervalSince1970
        }
        return .none

      case .proximityPauseUntilSelected(let pauseUntil):
        guard state.config.proximityAutoLock, pauseUntil > date.now else { return .none }
        state.$config.withLock {
          $0.proximityPauseUntil = pauseUntil.timeIntervalSince1970
        }
        return .none

      case .proximityPauseResumeTapped:
        state.$config.withLock { $0.proximityPauseUntil = nil }
        return .none

      case .proximityPauseExpired(let expectedDeadline):
        guard
          state.config.proximityPauseUntil == expectedDeadline.timeIntervalSince1970
        else {
          return .none
        }
        guard expectedDeadline <= date.now else {
          return proximityPauseTimer(for: state.config)
        }
        state.$config.withLock { $0.proximityPauseUntil = nil }
        return .none

      case .proximityDeviceSelected(let device):
        state.$config.withLock {
          $0.proximityDeviceID = device.id.uuidString
          $0.proximityDeviceName = device.name
        }
        return .none

      case .proximityModeChanged(let mode):
        state.$config.withLock { $0.proximityMode = mode }
        return .none

      case .proximitySensitivityChanged(let sensitivity):
        state.$config.withLock { $0.proximitySensitivity = sensitivity }
        return .none

      case .proximityRecalibrateTapped:
        return .run { _ in proximityLock.recalibrate() }

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
        let configuration = proximityMonitorConfiguration(newConfig)
        return .merge(
          .run { _ in
            proximityLock.monitor(configuration)
          },
          proximityPauseTimer(for: newConfig),
        )

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

  private enum CancelID {
    case proximityPauseTimer
  }

  /// The proximity fields that, when changed, require re-issuing monitor().
  private func proximityKey(_ config: AmadoConfig) -> String {
    let pauseUntil = config.proximityPauseUntil.map { String($0) } ?? ""
    return """
      \(config.proximityAutoLock)|\(pauseUntil)|\
      \(config.proximityDeviceID)|\(config.proximityMode.rawValue)|\
      \(config.proximitySensitivity.rawValue)|\(config.proximityFarRSSI)|\
      \(config.proximityGraceSeconds)|\(config.proximitySmoothing)
      """
  }

  private func proximityMonitorConfiguration(_ config: AmadoConfig) -> ProximityMonitorConfiguration {
    let isPaused = config.activeProximityPauseUntil(at: date.now) != nil
    return ProximityMonitorConfiguration(
      deviceID: config.proximityAutoLock && !isPaused ? UUID(uuidString: config.proximityDeviceID) : nil,
      mode: config.proximityMode,
      sensitivity: config.proximitySensitivity,
      manualFarRSSI: config.proximityFarRSSI,
      manualGraceSeconds: config.proximityGraceSeconds,
      manualSmoothing: config.proximitySmoothing,
    )
  }

  private func proximityPauseTimer(for config: AmadoConfig) -> Effect<Action> {
    guard let deadline = config.activeProximityPauseUntil(at: date.now) else {
      return .cancel(id: CancelID.proximityPauseTimer)
    }
    let delay = deadline.timeIntervalSince(date.now)
    return .run { send in
      try await clock.sleep(for: .seconds(delay))
      await send(.proximityPauseExpired(deadline))
    }
    .cancellable(id: CancelID.proximityPauseTimer, cancelInFlight: true)
  }

}

private var currentMacServiceName: String {
  Host.current().localizedName ?? "Mac"
}

extension ProximityDecisionEngine.LockReason {
  fileprivate var activityDescription: String {
    switch self {
    case .weakSignalTrend: "weakening signal"
    case .veryWeakSignal: "very weak signal"
    case .signalLostAfterWeakening: "signal lost after weakening"
    case .extendedSignalLoss: "signal unavailable while idle"
    case .manualThreshold: "manual threshold"
    case .manualSignalLoss: "manual signal-loss timeout"
    }
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
    case .mismatchedRequestNonce: "response/request nonce mismatch"
    }
  }
}
