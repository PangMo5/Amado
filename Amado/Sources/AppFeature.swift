// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
    var closedLidStatus = ClosedLidControlStatus.inactive
    var powerHelperStatus = PowerHelperInstallationStatus.checking
    var isApplyingClosedLidMode = false
    var isInstallingPowerHelper = false
    var isRefreshingPowerHelper = false
    var isRemovingPowerHelper = false
    /// Last closed-lid policy whose power state was submitted to the helper.
    /// This deduplicates the config publisher after an in-app edit while still
    /// applying edits made directly to config.toml.
    var appliedClosedLidMode = ClosedLidMode.off
    /// Everything currently wrong with the agent, worst first. Empty is the
    /// healthy state; entries are cleared by whichever subsystem recovers.
    var issues = [AgentIssue]()
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

    var activeAutoLockPause: AutoLockPause? {
      guard
        config.proximityAutoLock,
        !config.proximityDeviceID.isEmpty
      else { return nil }
      if config.closedLidMode == .unlocked, config.caffeinatePausesAutoLock {
        return .whileCaffeinating
      }
      return proximityPauseUntil.map(AutoLockPause.until)
    }

    /// The menu bar icon is compositional: the large lock, closed-lid marker,
    /// pause clock, and attention marker are derived independently.
    var menuBarIndicator: MenuBarIndicatorState {
      MenuBarIndicatorState(
        isAutoLockEnabled: config.proximityAutoLock,
        closedLidPolicy: closedLidStatus == .active
          ? config.closedLidMode.awakePolicy
          : nil,
        isAutoLockPaused: activeAutoLockPause != nil,
        needsAttention: !issues.isEmpty,
      )
    }

    var pairedClients: [PairedClient] {
      pairedClientRegistry.clients
    }

    /// What the menu bar should say. A problem still outranks healthy state,
    /// while active closed-lid mode preserves both its lock policy and an
    /// independent proximity-pause badge.
    var health: AgentHealth {
      if let issue = issues.first {
        return .impaired(issue)
      }
      let autoLockPause = activeAutoLockPause
      if
        closedLidStatus == .active,
        let policy = config.closedLidMode.awakePolicy
      {
        return .closedLidAwake(
          policy: policy,
          autoLockPause: autoLockPause,
        )
      }
      if let autoLockPause {
        return .paused(autoLockPause)
      }
      return isListening ? .listening : .starting
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
    case lanListenerStateChanged(LockListenerState)
    case remoteListenerStateChanged(RemoteListenerState)
    case screenLockAttempted(succeeded: Bool)
    case responseEncodingFailed(origin: String)
    case loginItemChanged(failure: String?)
    case issueRecoveryTapped(AgentIssue.Kind)
    case closedLidModeChanged(ClosedLidMode)
    case caffeinateSafetyConfirmationFinished(mode: ClosedLidMode, confirmed: Bool)
    case caffeinateAutoLockPauseChoiceSelected(CaffeinateAutoLockPauseChoice)
    case caffeinateHelperStatusRefreshTapped
    case caffeinateHelperStatusResponse(PowerHelperInstallationStatus)
    case caffeinateHelperSettingsTapped
    case caffeinateInstallHelperTapped
    case caffeinateInstallHelperResponse(PowerHelperInstallationStatus)
    case caffeinateRemoveHelperTapped
    case caffeinateRemoveHelperConfirmationFinished(Bool)
    case caffeinateRemoveHelperResponse(
      previousMode: ClosedLidMode,
      previousAutoLockPause: Bool,
      status: PowerHelperInstallationStatus,
    )
    case closedLidRetryTapped
    case closedLidApplyResponse(
      requestedMode: ClosedLidMode,
      previousMode: ClosedLidMode,
      status: ClosedLidControlStatus,
      userInitiated: Bool,
    )
    case closedLidStatusChanged(ClosedLidControlStatus)
    case lidStateChanged(isClosed: Bool)
    case builtinDisplayDimmingFinished(
      isDimmed: Bool,
      result: BuiltinDisplayDimmingResult,
    )
    case displaySleepFinished(DisplaySleepResult)
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
    case configChanged(AmadoConfig)
    case proximityFarDetected(ProximityDecisionEngine.LockReason)
  }

  @Dependency(\.caffeinatePrompt) var caffeinatePrompt
  @Dependency(\.closedLidControl) var closedLidControl
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date) var date
  @Dependency(\.lockListener) var lockListener
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.notifier) var notifier
  @Dependency(\.proximityLock) var proximityLock
  @Dependency(\.remoteListener) var remoteListener
  @Dependency(\.screenLocker) var screenLocker
  @Dependency(\.secretStore) var secretStore
  @Dependency(\.updater) var updater
  @Dependency(\.uuid) var uuid

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        // Resolving the live updater starts Sparkle's automatic check schedule.
        updater.start()
        // Make sure ~/.config/amado/ exists before the first config write.
        var startupEffects = [Effect<Action>]()
        do {
          try ConfigLocation.ensureDirectoryExists()
          startupEffects.append(resolve(.config, in: &state))
        } catch {
          startupEffects.append(raise(.config, detail: error.localizedDescription, in: &state))
        }
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
          startupEffects.append(store(secret, in: &state))
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
        state.appliedClosedLidMode = cfg.closedLidMode
        state.appliedProximityKey = proximityKey(cfg)
        let sharedConfig = state.$config
        let proximityConfiguration = proximityMonitorConfiguration(cfg)
        // Listen on both transports; `.received` verifies + dedups by nonce, so
        // a command arriving via LAN *and* the tunnel locks at most once.
        // Starting a listener is kept separate from consuming it: a listener
        // that fails to bind retries in the background, and the request loop
        // has to already be running when it finally comes up.
        startupEffects.append(contentsOf: [
          .run { _ in await lockListener.start() },
          .run { send in
            for await request in lockListener.incoming() {
              await send(.received(request))
            }
          },
          .run { send in
            for await listenerState in lockListener.state() {
              await send(.lanListenerStateChanged(listenerState))
            }
          },
          .run { _ in await remoteListener.start() },
          .run { send in
            for await request in remoteListener.incoming() {
              await send(.received(request))
            }
          },
          .run { send in
            for await listenerState in remoteListener.state() {
              await send(.remoteListenerStateChanged(listenerState))
            }
          },
          .run { send in
            for await isClosed in closedLidControl.lidChanges() {
              await send(.lidStateChanged(isClosed: isClosed))
            }
          },
          .run { send in
            for await status in closedLidControl.statusChanges() {
              await send(.closedLidStatusChanged(status))
            }
          },
          .run { send in
            await send(.caffeinateHelperStatusResponse(await closedLidControl.helperStatus()))
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
            // watcher). Power and proximity changes are deduplicated in
            // `.configChanged`.
            for await newConfig in sharedConfig.publisher.values {
              await send(.configChanged(newConfig))
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
        ])
        return .merge(startupEffects)

      case .lanListenerStateChanged(let listenerState):
        switch listenerState {
        case .ready:
          state.isListening = true
          return resolve(.lanListener, in: &state)

        case .unavailable(let reason):
          state.isListening = false
          return raise(.lanListener, detail: reason, in: &state)
        }

      case .remoteListenerStateChanged(let listenerState):
        switch listenerState {
        case .running:
          return resolve(.remoteListener, in: &state)

        case .stopped(let reason):
          return raise(.remoteListener, detail: reason, in: &state)
        }

      case .screenLockAttempted(let succeeded):
        return succeeded
          ? resolve(.screenLock, in: &state)
          : raise(
            .screenLock,
            detail: "This version of macOS no longer exposes the lock entry point Amado uses.",
            in: &state,
          )

      case .responseEncodingFailed(let origin):
        state.record(
          "Locked but could not answer \(origin)",
          kind: .rejected,
          id: uuid(),
          at: date.now,
        )
        return .none

      case .loginItemChanged(let failure):
        state.launchAtLogin = loginItem.isEnabled()
        guard let failure else { return resolve(.loginItem, in: &state) }
        return raise(.loginItem, detail: failure, in: &state)

      case .issueRecoveryTapped(let kind):
        switch kind {
        case .lanListener:
          return .run { _ in await lockListener.retry() }

        case .remoteListener:
          return .run { _ in await remoteListener.retry() }

        case .closedLidPower:
          guard
            let recovery = state.issues.first(where: { $0.kind == kind })?.recovery
          else { return .none }
          switch recovery {
          case .openLoginItems:
            return .run { _ in await closedLidControl.openHelperSettings() }

          case .retry:
            guard state.config.closedLidMode.keepsAwake else { return .none }
            state.isApplyingClosedLidMode = true
            return applyClosedLidMode(
              state.config.closedLidMode,
              previousMode: state.config.closedLidMode,
              userInitiated: true,
            )

          case .openSettings:
            return .none
          }

        case .bluetooth,
             .closedLidDisplay,
             .config,
             .loginItem,
             .pairingSecret,
             .screenLock:
          return .none
        }

      case .closedLidModeChanged(let mode):
        guard mode != state.config.closedLidMode else { return .none }
        guard !mode.keepsAwake || state.powerHelperStatus.isReady else { return .none }
        if mode.keepsAwake, !state.config.closedLidMode.keepsAwake {
          return .run { send in
            await send(
              .caffeinateSafetyConfirmationFinished(
                mode: mode,
                confirmed: await caffeinatePrompt.confirmSafety(),
              )
            )
          }
        }
        return requestClosedLidModeTransition(mode, in: &state)

      case .caffeinateSafetyConfirmationFinished(let mode, let confirmed):
        guard confirmed, mode.keepsAwake else { return .none }
        return requestClosedLidModeTransition(mode, in: &state)

      case .caffeinateAutoLockPauseChoiceSelected(.pause):
        return transitionClosedLidMode(
          .unlocked,
          caffeinatePausesAutoLock: true,
          in: &state,
        )

      case .caffeinateAutoLockPauseChoiceSelected(.keepAutoLockOn):
        return transitionClosedLidMode(
          .unlocked,
          caffeinatePausesAutoLock: false,
          in: &state,
        )

      case .caffeinateAutoLockPauseChoiceSelected(.cancel):
        return .none

      case .caffeinateHelperStatusRefreshTapped:
        guard !state.isRefreshingPowerHelper else { return .none }
        state.isRefreshingPowerHelper = true
        return .run { send in
          await send(.caffeinateHelperStatusResponse(await closedLidControl.helperStatus()))
        }

      case .caffeinateHelperStatusResponse(let status):
        state.isRefreshingPowerHelper = false
        state.powerHelperStatus = status
        switch status {
        case .installed:
          guard
            state.config.closedLidMode.keepsAwake,
            state.closedLidStatus != .active,
            !state.isApplyingClosedLidMode
          else { return resolve(.closedLidPower, in: &state) }
          state.isApplyingClosedLidMode = true
          return applyClosedLidMode(
            state.config.closedLidMode,
            previousMode: .off,
            userInitiated: false,
          )

        case .notInstalled,
             .requiresApproval,
             .updateAvailable,
             .installationFailed,
             .failed:
          return resetUnavailableCaffeinate(in: &state)

        case .checking:
          return .none
        }

      case .caffeinateHelperSettingsTapped:
        return .run { _ in await closedLidControl.openHelperSettings() }

      case .caffeinateInstallHelperTapped:
        guard
          state.powerHelperStatus.canInstall,
          !state.isInstallingPowerHelper,
          !state.isRemovingPowerHelper
        else { return .none }
        state.isInstallingPowerHelper = true
        return .run { send in
          await send(.caffeinateInstallHelperResponse(await closedLidControl.installHelper()))
        }

      case .caffeinateInstallHelperResponse(let status):
        state.isInstallingPowerHelper = false
        state.powerHelperStatus = status
        switch status {
        case .installed:
          guard state.config.closedLidMode.keepsAwake else {
            return resolve(.closedLidPower, in: &state)
          }
          state.isApplyingClosedLidMode = true
          return applyClosedLidMode(
            state.config.closedLidMode,
            previousMode: state.config.closedLidMode,
            userInitiated: true,
          )

        case .requiresApproval:
          let issue = raise(
            .closedLidPower,
            detail: status.summary,
            recovery: .openLoginItems,
            in: &state,
          )
          return .merge(
            issue,
            .run { _ in await closedLidControl.openHelperSettings() },
          )

        case .installationFailed,
             .failed:
          return raise(
            .closedLidPower,
            detail: status.summary,
            in: &state,
          )

        case .checking,
             .notInstalled,
             .updateAvailable:
          return .none
        }

      case .caffeinateRemoveHelperTapped:
        guard
          state.powerHelperStatus.canRemove,
          !state.isInstallingPowerHelper,
          !state.isRemovingPowerHelper
        else { return .none }
        return .run { send in
          await send(
            .caffeinateRemoveHelperConfirmationFinished(
              await caffeinatePrompt.confirmHelperRemoval()
            )
          )
        }

      case .caffeinateRemoveHelperConfirmationFinished(false):
        return .none

      case .caffeinateRemoveHelperConfirmationFinished(true):
        let previousMode = state.config.closedLidMode
        let previousAutoLockPause = state.config.caffeinatePausesAutoLock
        state.isRemovingPowerHelper = true
        state.isApplyingClosedLidMode = false
        state.$config.withLock {
          $0.closedLidMode = .off
          $0.caffeinatePausesAutoLock = false
        }
        state.appliedClosedLidMode = .off
        return .merge(
          .cancel(id: CancelID.closedLidApply),
          .run { send in
            let status = await closedLidControl.removeHelper()
            await send(
              .caffeinateRemoveHelperResponse(
                previousMode: previousMode,
                previousAutoLockPause: previousAutoLockPause,
                status: status,
              )
            )
          },
        )

      case .caffeinateRemoveHelperResponse(let previousMode, let previousAutoLockPause, let status):
        state.isRemovingPowerHelper = false
        state.powerHelperStatus = status
        guard status == .notInstalled else {
          state.$config.withLock {
            $0.closedLidMode = previousMode
            $0.caffeinatePausesAutoLock = previousAutoLockPause
          }
          state.appliedClosedLidMode = previousMode
          let failure = ClosedLidControlStatus.failed(
            "Power Helper removal did not finish: \(status.diagnostic)"
          )
          state.closedLidStatus = failure
          return raise(
            .closedLidPower,
            detail: failure.summary,
            in: &state,
          )
        }
        state.closedLidStatus = .inactive
        return .merge(
          resolve(.closedLidPower, in: &state),
          resolve(.closedLidDisplay, in: &state),
        )

      case .closedLidRetryTapped:
        guard state.config.closedLidMode.keepsAwake else { return .none }
        state.isApplyingClosedLidMode = true
        return applyClosedLidMode(
          state.config.closedLidMode,
          previousMode: state.config.closedLidMode,
          userInitiated: true,
        )

      case .closedLidApplyResponse(let requestedMode, let previousMode, let status, let userInitiated):
        state.isApplyingClosedLidMode = false
        state.closedLidStatus = status
        switch status {
        case .active,
             .inactive:
          if status == .active {
            state.powerHelperStatus = .installed(.current)
          }
          return resolve(.closedLidPower, in: &state)

        case .helperNotInstalled:
          state.powerHelperStatus = .notInstalled
          return raise(
            .closedLidPower,
            detail: status.summary,
            in: &state,
          )

        case .requiresApproval:
          state.powerHelperStatus = .requiresApproval
          let issue = raise(
            .closedLidPower,
            detail: status.summary,
            recovery: .openLoginItems,
            interrupts: !userInitiated,
            in: &state,
          )
          guard userInitiated else { return issue }
          return .merge(
            issue,
            .run { _ in await closedLidControl.openHelperSettings() },
          )

        case .unsupported:
          state.$config.withLock { $0.closedLidMode = .off }
          state.appliedClosedLidMode = .off
          return raise(
            .closedLidPower,
            detail: status.summary,
            interrupts: false,
            in: &state,
          )

        case .failed:
          // A failed Off may mean the privileged global override is still on.
          // Restore the previous awake policy so the UI never claims normal
          // sleep was restored, and make the repair action explicit.
          if !requestedMode.keepsAwake {
            state.$config.withLock {
              $0.closedLidMode = previousMode.keepsAwake ? previousMode : .lock
            }
            state.appliedClosedLidMode = state.config.closedLidMode
          }
          return raise(
            .closedLidPower,
            detail: status.summary,
            recovery: .retry,
            in: &state,
          )
        }

      case .closedLidStatusChanged(let status):
        state.closedLidStatus = status
        switch status {
        case .active:
          state.powerHelperStatus = .installed(.current)
          return resolve(.closedLidPower, in: &state)

        case .inactive:
          guard state.config.closedLidMode.keepsAwake else {
            return resolve(.closedLidPower, in: &state)
          }
          return raise(
            .closedLidPower,
            detail: "The Power Helper restored normal lid sleep unexpectedly",
            recovery: .retry,
            in: &state,
          )

        case .requiresApproval:
          state.powerHelperStatus = .requiresApproval
          return raise(
            .closedLidPower,
            detail: status.summary,
            recovery: .openLoginItems,
            in: &state,
          )

        case .helperNotInstalled:
          state.powerHelperStatus = .notInstalled
          return raise(
            .closedLidPower,
            detail: status.summary,
            in: &state,
          )

        case .unsupported:
          state.$config.withLock { $0.closedLidMode = .off }
          state.appliedClosedLidMode = .off
          return raise(
            .closedLidPower,
            detail: status.summary,
            interrupts: false,
            in: &state,
          )

        case .failed:
          return raise(
            .closedLidPower,
            detail: status.summary,
            recovery: .retry,
            in: &state,
          )
        }

      case .lidStateChanged(let isClosed):
        if !isClosed {
          return .run { send in
            let result = await closedLidControl.setBuiltinDisplayDimmed(false)
            await send(.builtinDisplayDimmingFinished(isDimmed: false, result: result))
          }
        }
        guard
          state.config.closedLidMode.keepsAwake,
          state.closedLidStatus == .active
        else { return .none }
        if state.config.closedLidMode == .lock {
          state.record(
            "Locked — MacBook lid closed",
            kind: .locked,
            id: uuid(),
            at: date.now,
          )
          return .run { send in
            await send(.screenLockAttempted(succeeded: screenLocker.lock()))
            await send(.displaySleepFinished(await closedLidControl.sleepDisplays()))
          }
        }
        return .run { send in
          let result = await closedLidControl.setBuiltinDisplayDimmed(true)
          await send(.builtinDisplayDimmingFinished(isDimmed: true, result: result))
        }

      case .builtinDisplayDimmingFinished(_, .applied):
        return resolve(.closedLidDisplay, in: &state)

      case .builtinDisplayDimmingFinished(let isDimmed, .failed(let detail)):
        return raise(
          .closedLidDisplay,
          detail: isDimmed
            ? detail
            : "The lid opened, but the previous brightness was not restored: \(detail)",
          in: &state,
        )

      case .displaySleepFinished(.applied):
        return resolve(.closedLidDisplay, in: &state)

      case .displaySleepFinished(.failed(let detail)):
        return raise(.closedLidDisplay, detail: detail, in: &state)

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
              await send(.screenLockAttempted(succeeded: screenLocker.lock()))
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
                // Leaving the caller to time out would tell it nothing, so say
                // the response could not be produced.
                await send(.responseEncodingFailed(origin: command.origin))
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
        return .run { send in
          await send(.screenLockAttempted(succeeded: screenLocker.lock()))
        }

      case .checkForUpdatesTapped:
        updater.checkForUpdates()
        return .none

      case .regenerateSecretTapped:
        let secret = PairingSecret.generate()
        state.pairingSecretBase64 = secret.base64
        let stored = store(secret, in: &state)
        state.recentNonces.removeAll()
        state.$pairedClientRegistry.withLock { $0 = PairedClientRegistry() }
        state.record("Pairing secret regenerated — re-pair your devices", kind: .rejected, id: uuid(), at: date.now)
        return stored

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
        return .run { send in
          await send(.loginItemChanged(failure: loginItem.setEnabled(enabled)))
        }

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
          state.config.activeAutoLockPause(at: date.now) == nil
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
        return .run { send in
          await send(.screenLockAttempted(succeeded: screenLocker.lock()))
        }

      case .proximityStatusChanged(let proximityStatus):
        state.proximityStatus = proximityStatus
        // Bluetooth being off only matters when auto-lock is actually set up;
        // otherwise the radio is nobody's business.
        guard
          state.config.proximityAutoLock,
          !state.config.proximityDeviceID.isEmpty,
          case .waitingForBluetooth(let reason) = proximityStatus
        else {
          return resolve(.bluetooth, in: &state)
        }
        return raise(
          .bluetooth,
          detail: reason.summary,
          recovery: bluetoothRecovery(for: reason),
          interrupts: reason.needsUserAction,
          in: &state,
        )

      case .proximityAutoLockToggled(let on):
        // Persist only; the config observer re-issues monitor().
        state.$config.withLock {
          $0.proximityAutoLock = on
          if !on {
            $0.caffeinatePausesAutoLock = false
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
        state.$config.withLock {
          $0.caffeinatePausesAutoLock = false
          $0.proximityPauseUntil = nil
        }
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

      case .configChanged(let newConfig):
        var effects = [Effect<Action>]()

        let previousClosedLidMode = state.appliedClosedLidMode
        let newClosedLidMode = newConfig.closedLidMode
        if newClosedLidMode != previousClosedLidMode {
          if newClosedLidMode.keepsAwake, !state.powerHelperStatus.isReady {
            state.$config.withLock {
              $0.closedLidMode = .off
              $0.caffeinatePausesAutoLock = false
            }
            state.appliedClosedLidMode = .off
          } else {
            state.appliedClosedLidMode = newClosedLidMode
            if
              !previousClosedLidMode.keepsAwake
              || !newClosedLidMode.keepsAwake
              || state.closedLidStatus != .active
            {
              state.isApplyingClosedLidMode = true
              effects.append(
                applyClosedLidMode(
                  newClosedLidMode,
                  previousMode: previousClosedLidMode,
                  userInitiated: false,
                )
              )
            }
          }
        }

        let key = proximityKey(newConfig)
        if key != state.appliedProximityKey {
          state.appliedProximityKey = key
          let configuration = proximityMonitorConfiguration(newConfig)
          effects.append(
            .run { _ in
              proximityLock.monitor(configuration)
            }
          )
          effects.append(proximityPauseTimer(for: newConfig))
        }
        return .merge(effects)

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
    case closedLidApply
    case proximityPauseTimer
  }

  /// Record a problem and, the first time a subsystem breaks, interrupt with a
  /// notification. Re-raising the same issue only refreshes its wording: a
  /// listener retrying every 30 seconds must not notify every 30 seconds.
  private func raise(
    _ kind: AgentIssue.Kind,
    detail: String,
    recovery: AgentIssueRecovery? = nil,
    interrupts: Bool = true,
    in state: inout State,
  ) -> Effect<Action> {
    let wasHealthy = !state.issues.contains { $0.kind == kind }
    let issue = AgentIssue(kind: kind, detail: detail, recovery: recovery)
    guard wasHealthy || state.issues.first(where: { $0.kind == kind }) != issue else { return .none }
    state.issues.removeAll { $0.kind == kind }
    state.issues.append(issue)
    state.issues.sort { $0.kind.severity < $1.kind.severity }

    guard wasHealthy, interrupts, kind.interrupts else { return .none }
    return .run { _ in
      await notifier.post(id: kind.rawValue, title: issue.title, body: detail)
    }
  }

  private func resolve(_ kind: AgentIssue.Kind, in state: inout State) -> Effect<Action> {
    guard state.issues.contains(where: { $0.kind == kind }) else { return .none }
    state.issues.removeAll { $0.kind == kind }
    return .run { _ in await notifier.withdraw(id: kind.rawValue) }
  }

  /// Persist a freshly minted pairing secret, reporting a Keychain refusal
  /// rather than letting the pairing silently expire at the next launch.
  private func store(_ secret: PairingSecret, in state: inout State) -> Effect<Action> {
    guard secretStore.save(secret.base64) else {
      return raise(
        .pairingSecret,
        detail: "macOS refused to store the pairing secret in your login Keychain.",
        in: &state,
      )
    }
    return resolve(.pairingSecret, in: &state)
  }

  private func transitionClosedLidMode(
    _ mode: ClosedLidMode,
    caffeinatePausesAutoLock: Bool? = nil,
    in state: inout State,
  ) -> Effect<Action> {
    let previousMode = state.config.closedLidMode
    guard mode != previousMode else { return .none }
    guard !mode.keepsAwake || state.powerHelperStatus.isReady else { return .none }
    state.$config.withLock {
      $0.closedLidMode = mode
      if let caffeinatePausesAutoLock {
        $0.caffeinatePausesAutoLock = caffeinatePausesAutoLock
      }
    }
    state.appliedClosedLidMode = mode

    // Switching between the two awake policies changes only what happens on
    // the next lid-close transition; the existing helper lease remains valid.
    if
      previousMode.keepsAwake,
      mode.keepsAwake,
      state.closedLidStatus == .active
    {
      return .none
    }
    state.isApplyingClosedLidMode = true
    return applyClosedLidMode(
      mode,
      previousMode: previousMode,
      userInitiated: true,
    )
  }

  private func requestClosedLidModeTransition(
    _ mode: ClosedLidMode,
    in state: inout State,
  ) -> Effect<Action> {
    guard mode != state.config.closedLidMode else { return .none }
    if mode == .unlocked, state.config.proximityAutoLock {
      return .run { send in
        await send(
          .caffeinateAutoLockPauseChoiceSelected(
            await caffeinatePrompt.askAutoLockPause()
          )
        )
      }
    }
    return transitionClosedLidMode(mode, in: &state)
  }

  private func resetUnavailableCaffeinate(in state: inout State) -> Effect<Action> {
    guard
      state.config.closedLidMode.keepsAwake
      || state.config.caffeinatePausesAutoLock
      || state.isApplyingClosedLidMode
    else { return .none }
    state.$config.withLock {
      $0.closedLidMode = .off
      $0.caffeinatePausesAutoLock = false
    }
    state.appliedClosedLidMode = .off
    state.closedLidStatus = .inactive
    state.isApplyingClosedLidMode = false
    return .merge(
      .cancel(id: CancelID.closedLidApply),
      resolve(.closedLidPower, in: &state),
    )
  }

  private func applyClosedLidMode(
    _ mode: ClosedLidMode,
    previousMode: ClosedLidMode,
    userInitiated: Bool,
  ) -> Effect<Action> {
    .run { send in
      let status = await closedLidControl.setEnabled(mode.keepsAwake)
      await send(
        .closedLidApplyResponse(
          requestedMode: mode,
          previousMode: previousMode,
          status: status,
          userInitiated: userInitiated,
        )
      )
    }
    .cancellable(id: CancelID.closedLidApply, cancelInFlight: true)
  }

  private func bluetoothRecovery(for reason: BluetoothUnavailability) -> AgentIssueRecovery? {
    switch reason {
    case .poweredOff:
      SystemSettings.bluetooth.map(AgentIssueRecovery.openSettings)

    case .unauthorized:
      SystemSettings.bluetoothPrivacy.map(AgentIssueRecovery.openSettings)

    // Nothing in System Settings fixes a missing radio or a restarting one.
    case .resetting,
         .unknown,
         .unsupported:
      nil
    }
  }

  /// The proximity fields that, when changed, require re-issuing monitor().
  private func proximityKey(_ config: AmadoConfig) -> String {
    let pauseUntil = config.proximityPauseUntil.map { String($0) } ?? ""
    return """
      \(config.proximityAutoLock)|\(pauseUntil)|\
      \(config.closedLidMode.rawValue)|\(config.caffeinatePausesAutoLock)|\
      \(config.proximityDeviceID)|\(config.proximityMode.rawValue)|\
      \(config.proximitySensitivity.rawValue)|\(config.proximityFarRSSI)|\
      \(config.proximityGraceSeconds)|\(config.proximitySmoothing)
      """
  }

  private func proximityMonitorConfiguration(_ config: AmadoConfig) -> ProximityMonitorConfiguration {
    let isPaused = config.activeAutoLockPause(at: date.now) != nil
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
