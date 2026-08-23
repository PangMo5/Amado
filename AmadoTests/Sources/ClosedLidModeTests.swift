// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing
import Testing

@testable import Amado

// MARK: - ClosedLidModeTests

@MainActor
@Suite("Closed-lid mode")
struct ClosedLidModeTests {

  // MARK: Internal

  @Test
  func `enabling persists intent and reports the active helper`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder)
    store.dependencies.closedLidControl.setEnabled = { enabled in
      await recorder.applied(enabled: enabled)
      return .active
    }

    await store.send(.closedLidModeChanged(.lock))
    await store.receive(\.caffeinateSafetyConfirmationFinished) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.closedLidStatus = .active
      $0.isApplyingClosedLidMode = false
    }

    await store.finish()
    #expect(await recorder.applies == [.init(enabled: true)])
  }

  @Test
  func `cancelling the Caffeinate safety warning preserves normal sleep`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder)
    store.dependencies.caffeinatePrompt.confirmSafety = { false }

    await store.send(.closedLidModeChanged(.lock))
    await store.receive(\.caffeinateSafetyConfirmationFinished)

    #expect(store.state.config.closedLidMode == .off)
    await store.finish()
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `awake policy is ignored until the Power Helper is installed`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.powerHelperStatus = .notInstalled
    }

    await store.send(.closedLidModeChanged(.lock))

    #expect(store.state.config.closedLidMode == .off)
    await store.finish()
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `missing Power Helper resets a persisted awake policy`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .lock
      $0.powerHelperStatus = .checking
    }

    await store.send(.caffeinateHelperStatusResponse(.notInstalled)) {
      $0.$config.withLock {
        $0.closedLidMode = .off
        $0.caffeinatePausesAutoLock = false
      }
      $0.appliedClosedLidMode = .off
      $0.powerHelperStatus = .notInstalled
    }

    await store.finish()
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `installed Power Helper restores a persisted awake policy`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.powerHelperStatus = .checking
    }

    await store.send(.caffeinateHelperStatusResponse(.installed(.current))) {
      $0.powerHelperStatus = .installed(.current)
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.closedLidStatus = .active
      $0.isApplyingClosedLidMode = false
    }

    await store.finish()
    #expect(await recorder.applies == [.init(enabled: true)])
  }

  @Test
  func `installing the Power Helper is an explicit action`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.powerHelperStatus = .notInstalled
    }

    await store.send(.caffeinateInstallHelperTapped) {
      $0.isInstallingPowerHelper = true
    }
    await store.receive(\.caffeinateInstallHelperResponse) {
      $0.powerHelperStatus = .installed(.current)
      $0.isInstallingPowerHelper = false
    }

    await store.finish()
    #expect(await recorder.helperInstallCount == 1)
  }

  @Test
  func `failed Power Helper installation can be retried without relaunching`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.powerHelperStatus = .installationFailed(
        "SMAppServiceErrorDomain 1: Operation not permitted"
      )
    }

    #expect(store.state.powerHelperStatus.canInstall)
    #expect(!store.state.powerHelperStatus.canRemove)
    #expect(store.state.powerHelperStatus.installButtonTitle == "Try Install Again")

    await store.send(.caffeinateInstallHelperTapped) {
      $0.isInstallingPowerHelper = true
    }
    await store.receive(\.caffeinateInstallHelperResponse) {
      $0.powerHelperStatus = .installed(.current)
      $0.isInstallingPowerHelper = false
    }

    await store.finish()
    #expect(await recorder.helperInstallCount == 1)
  }

  @Test
  func `Debug and Release use separate Power Helper identities`() {
    #expect(PowerHelperIdentity.debug != PowerHelperIdentity.release)
    #expect(
      PowerHelperIdentity.debug.helperIdentifier
        == "dev.PangMo5.Amado.debug.PowerHelper"
    )
    #expect(
      PowerHelperIdentity.release.helperIdentifier
        == "dev.PangMo5.Amado.PowerHelper"
    )
    #if DEBUG
    #expect(PowerHelperConstants.identity == .debug)
    #endif
  }

  @Test
  func `bundled Power Helper requires both its plist and executable`() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let daemons = root.appending(
      path: "Contents/Library/LaunchDaemons",
      directoryHint: .isDirectory,
    )
    let executables = root.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let identity = PowerHelperIdentity.debug
    let plist = daemons.appending(path: identity.plistName)
    let executable = executables.appending(path: "AmadoPowerHelper")
    try Data().write(to: plist)
    #expect(!identity.isBundled(in: root))

    try Data().write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path,
    )
    #expect(identity.isBundled(in: root))
  }

  @Test
  func `Power Helper removal is ignored when it is not installed`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.powerHelperStatus = .notInstalled
    }

    await store.send(.caffeinateRemoveHelperTapped)

    await store.finish()
    #expect(await recorder.helperRemovalCount == 0)
  }

  @Test
  func `cancelling Power Helper removal preserves Caffeinate`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }
    store.dependencies.caffeinatePrompt.confirmHelperRemoval = { false }

    await store.send(.caffeinateRemoveHelperTapped)
    await store.receive(\.caffeinateRemoveHelperConfirmationFinished)

    #expect(store.state.config.closedLidMode == .lock)
    #expect(store.state.closedLidStatus == .active)
    await store.finish()
    #expect(await recorder.helperRemovalCount == 0)
  }

  @Test
  func `removing Power Helper turns off Caffeinate and its auto-lock pause`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .unlocked
      $0.closedLidStatus = .active
    }
    store.dependencies.caffeinatePrompt.confirmHelperRemoval = { true }

    await store.send(.caffeinateRemoveHelperTapped)
    await store.receive(\.caffeinateRemoveHelperConfirmationFinished) {
      $0.$config.withLock {
        $0.closedLidMode = .off
        $0.caffeinatePausesAutoLock = false
      }
      $0.appliedClosedLidMode = .off
      $0.isRemovingPowerHelper = true
    }
    await store.receive(\.caffeinateRemoveHelperResponse) {
      $0.closedLidStatus = .inactive
      $0.powerHelperStatus = .notInstalled
      $0.isRemovingPowerHelper = false
    }

    await store.finish()
    #expect(await recorder.helperRemovalCount == 1)
  }

  @Test
  func `failed Power Helper removal restores the previous Caffeinate policy`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .unlocked
      $0.closedLidStatus = .active
    }
    store.dependencies.caffeinatePrompt.confirmHelperRemoval = { true }
    let (removalStatuses, removalStatusContinuation) =
      AsyncStream<PowerHelperInstallationStatus>.makeStream()
    store.dependencies.closedLidControl.removeHelper = {
      await removalStatuses.first(where: { _ in true }) ?? .notInstalled
    }

    await store.send(.caffeinateRemoveHelperTapped)
    await store.receive(\.caffeinateRemoveHelperConfirmationFinished) {
      $0.$config.withLock {
        $0.closedLidMode = .off
        $0.caffeinatePausesAutoLock = false
      }
      $0.appliedClosedLidMode = .off
      $0.isRemovingPowerHelper = true
    }
    removalStatusContinuation.yield(
      .failed(reason: "The helper is still registered", isRegistered: true)
    )
    removalStatusContinuation.finish()
    await store.receive(\.caffeinateRemoveHelperResponse) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .unlocked
      $0.powerHelperStatus = .failed(
        reason: "The helper is still registered",
        isRegistered: true,
      )
      $0.closedLidStatus = .failed(
        "Power Helper removal did not finish: The helper is still registered"
      )
      $0.isRemovingPowerHelper = false
      $0.issues = [
        AgentIssue(
          kind: .closedLidPower,
          detail: "Unavailable: Power Helper removal did not finish: The helper is still registered",
        )
      ]
    }

    await store.finish()
  }

  @Test
  func `unlocked Caffeinate combines operational security and auto-lock choices`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.proximityAutoLock = true
        $0.proximityDeviceID = Self.deviceID.uuidString
      }
    }
    let prompts = KeepUnlockedPromptRecorder(
      choice: .keepUnlocked(pausingAutoLock: true)
    )
    store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { includesSafety, autoLock in
      await prompts.choose(includesOperationalSafety: includesSafety, autoLockEnabled: autoLock)
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateKeepUnlockedChoiceSelected) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .unlocked
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.closedLidStatus = .active
      $0.isApplyingClosedLidMode = false
    }

    #expect(store.state.activeAutoLockPause == .whileCaffeinating)
    await store.finish()
    #expect(
      await prompts.requests == [
        .init(includesOperationalSafety: true, autoLockEnabled: true)
      ]
    )
    #expect(await recorder.applies == [.init(enabled: true)])
  }

  @Test
  func `switching awake policy keeps the existing helper lease`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }
    let prompts = KeepUnlockedPromptRecorder(
      choice: .keepUnlocked(pausingAutoLock: false)
    )
    store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { includesSafety, autoLock in
      await prompts.choose(includesOperationalSafety: includesSafety, autoLockEnabled: autoLock)
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateKeepUnlockedChoiceSelected) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = false
      }
      $0.appliedClosedLidMode = .unlocked
    }

    await store.finish()
    #expect(
      await prompts.requests == [
        .init(includesOperationalSafety: false, autoLockEnabled: false)
      ]
    )
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `unlocked Caffeinate asks whether to pause enabled auto-lock`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.proximityAutoLock = true
        $0.proximityDeviceID = Self.deviceID.uuidString
      }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }
    let prompts = KeepUnlockedPromptRecorder(
      choice: .keepUnlocked(pausingAutoLock: true)
    )
    store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { includesSafety, autoLock in
      await prompts.choose(includesOperationalSafety: includesSafety, autoLockEnabled: autoLock)
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateKeepUnlockedChoiceSelected) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .unlocked
    }

    #expect(store.state.activeAutoLockPause == .whileCaffeinating)
    await store.finish()
    #expect(
      await prompts.requests == [
        .init(includesOperationalSafety: false, autoLockEnabled: true)
      ]
    )
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `unlocked Caffeinate can leave auto-lock running`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.proximityAutoLock = true
        $0.proximityDeviceID = Self.deviceID.uuidString
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }
    let prompts = KeepUnlockedPromptRecorder(
      choice: .keepUnlocked(pausingAutoLock: false)
    )
    store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { includesSafety, autoLock in
      await prompts.choose(includesOperationalSafety: includesSafety, autoLockEnabled: autoLock)
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateKeepUnlockedChoiceSelected) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = false
      }
      $0.appliedClosedLidMode = .unlocked
    }

    #expect(store.state.activeAutoLockPause == nil)
    await store.finish()
    #expect(
      await prompts.requests == [
        .init(includesOperationalSafety: false, autoLockEnabled: true)
      ]
    )
  }

  @Test
  func `cancelling the combined unlocked prompt preserves the locked policy`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.proximityAutoLock = true
      }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }
    let prompts = KeepUnlockedPromptRecorder(choice: .cancel)
    store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { includesSafety, autoLock in
      await prompts.choose(includesOperationalSafety: includesSafety, autoLockEnabled: autoLock)
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateKeepUnlockedChoiceSelected)

    #expect(store.state.config.closedLidMode == .lock)
    await store.finish()
    #expect(
      await prompts.requests == [
        .init(includesOperationalSafety: false, autoLockEnabled: true)
      ]
    )
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `cancelling the combined unlocked warning preserves normal sleep`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder)
    let prompts = KeepUnlockedPromptRecorder(choice: .cancel)
    store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { includesSafety, autoLock in
      await prompts.choose(includesOperationalSafety: includesSafety, autoLockEnabled: autoLock)
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateKeepUnlockedChoiceSelected)

    #expect(store.state.config.closedLidMode == .off)
    await store.finish()
    #expect(
      await prompts.requests == [
        .init(includesOperationalSafety: true, autoLockEnabled: false)
      ]
    )
    #expect(await recorder.applies.isEmpty)
  }

  @Test
  func `external config edit applies the new power state`() async {
    let recorder = ClosedLidRecorder()
    let config = AmadoConfig(closedLidMode: .lock)
    let store = makeStore(recorder) {
      $0.$config.withLock { $0 = config }
      $0.appliedProximityKey = "false||lock|false||smart|balanced|-56|2.0|3"
    }

    await store.send(.configChanged(config)) {
      $0.appliedClosedLidMode = .lock
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.closedLidStatus = .active
      $0.isApplyingClosedLidMode = false
    }

    await store.finish()
    #expect(await recorder.applies == [.init(enabled: true)])
  }

  @Test
  func `failed disable restores the previous awake policy`() async {
    let recorder = ClosedLidRecorder()
    let failure = ClosedLidControlStatus.failed("normal sleep was not restored")
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .unlocked }
      $0.appliedClosedLidMode = .unlocked
      $0.closedLidStatus = .active
    }
    store.dependencies.closedLidControl.setEnabled = { _ in failure }

    await store.send(.closedLidModeChanged(.off)) {
      $0.$config.withLock { $0.closedLidMode = .off }
      $0.appliedClosedLidMode = .off
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.$config.withLock { $0.closedLidMode = .unlocked }
      $0.appliedClosedLidMode = .unlocked
      $0.closedLidStatus = failure
      $0.isApplyingClosedLidMode = false
      $0.issues = [
        AgentIssue(
          kind: .closedLidPower,
          detail: failure.summary,
          recovery: .retry,
        )
      ]
    }

    await store.finish()
  }

  @Test
  func `closing the lid locks by default and sleeps the displays`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.closedLidStatus = .active
    }
    store.dependencies.screenLocker.lock = { true }

    await store.send(.lidStateChanged(isClosed: true)) {
      $0.activity = [
        ActivityEntry(
          id: Self.eventID,
          at: Self.now,
          message: "Locked — MacBook lid closed",
          kind: .locked,
        )
      ]
    }
    await store.receive(\.screenLockAttempted)
    await store.receive(\.displaySleepFinished)

    await store.finish()
    #expect(await recorder.displayDimmingStates.isEmpty)
    #expect(await recorder.displaySleepCount == 1)
  }

  @Test
  func `closing the lid can dim the display while leaving the session unlocked`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .unlocked }
      $0.closedLidStatus = .active
    }
    store.dependencies.screenLocker.lock = {
      Issue.record("Screen lock must not run in unlocked closed-lid mode")
      return true
    }

    await store.send(.lidStateChanged(isClosed: true))
    await store.receive(\.builtinDisplayDimmingFinished)

    await store.finish()
    #expect(store.state.activity.isEmpty)
    #expect(await recorder.displayDimmingStates == [true])
  }

  @Test
  func `proximity auto-lock locks without sleeping displays while Caffeinate is active`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.proximityAutoLock = true
        $0.proximityDeviceID = Self.deviceID.uuidString
      }
      $0.closedLidStatus = .active
    }
    store.dependencies.screenLocker.lock = { true }

    await store.send(.proximityFarDetected(.veryWeakSignal)) {
      $0.activity = [
        ActivityEntry(
          id: Self.eventID,
          at: Self.now,
          message: "Locked — your iPhone left (very weak signal)",
          kind: .locked,
        )
      ]
    }
    await store.receive(\.screenLockAttempted)

    await store.finish()
    #expect(await recorder.displaySleepCount == 0)
  }

  @Test
  func `Caffeinate auto-lock pause suppresses a proximity lock`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.proximityAutoLock = true
        $0.proximityDeviceID = Self.deviceID.uuidString
        $0.caffeinatePausesAutoLock = true
      }
      $0.closedLidStatus = .active
    }
    store.dependencies.screenLocker.lock = {
      Issue.record("Screen lock must not run while Caffeinate pauses auto-lock")
      return true
    }

    await store.send(.proximityFarDetected(.veryWeakSignal))

    await store.finish()
    #expect(store.state.activity.isEmpty)
  }

  @Test
  func `opening the lid restores the built-in display`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .unlocked }
      $0.closedLidStatus = .active
    }

    await store.send(.lidStateChanged(isClosed: false))
    await store.receive(\.builtinDisplayDimmingFinished)

    await store.finish()
    #expect(await recorder.displayDimmingStates == [false])
  }

  @Test
  func `display dimming failure is visible`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .unlocked }
      $0.closedLidStatus = .active
    }
    let failure = "The built-in display backlight could not be turned off"
    store.dependencies.closedLidControl.setBuiltinDisplayDimmed = { _ in .failed(failure) }

    await store.send(.lidStateChanged(isClosed: true))
    await store.receive(\.builtinDisplayDimmingFinished) {
      $0.issues = [AgentIssue(kind: .closedLidDisplay, detail: failure)]
    }

    await store.finish()
  }

  @Test
  func `helper approval is visible and opens Login Items settings`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder)
    store.dependencies.closedLidControl.setEnabled = { _ in .requiresApproval }
    store.dependencies.closedLidControl.openHelperSettings = { await recorder.openedSettings() }

    await store.send(.closedLidModeChanged(.lock))
    await store.receive(\.caffeinateSafetyConfirmationFinished) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.closedLidStatus = .requiresApproval
      $0.powerHelperStatus = .requiresApproval
      $0.isApplyingClosedLidMode = false
      $0.issues = [
        AgentIssue(
          kind: .closedLidPower,
          detail: ClosedLidControlStatus.requiresApproval.summary,
          recovery: .openLoginItems,
        )
      ]
    }

    await store.finish()
    #expect(await recorder.settingsOpenCount == 1)
  }

  // MARK: Private

  private static let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
  private static let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!
  private static let now = Date(timeIntervalSince1970: 1_234)

  private func makeStore(
    _ recorder: ClosedLidRecorder,
    configure: (inout AppFeature.State) -> Void = { _ in },
  ) -> TestStoreOf<AppFeature> {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.date = .constant(Self.now)
      $0.uuid = .constant(Self.eventID)
    } operation: {
      var state = AppFeature.State()
      state.powerHelperStatus = .installed(.current)
      configure(&state)
      let store = TestStore(initialState: state) {
        AppFeature()
      }
      store.dependencies.notifier = NotifierClient(
        post: { _, _, _ in },
        withdraw: { _ in },
      )
      store.dependencies.caffeinatePrompt.confirmSafety = { true }
      store.dependencies.caffeinatePrompt.chooseKeepUnlocked = { _, _ in
        .keepUnlocked(pausingAutoLock: false)
      }
      store.dependencies.closedLidControl = ClosedLidControlClient(
        setEnabled: { enabled in
          await recorder.applied(enabled: enabled)
          return enabled ? .active : .inactive
        },
        helperStatus: { .installed(.current) },
        installHelper: { await recorder.installedHelper() },
        removeHelper: { await recorder.removedHelper() },
        openHelperSettings: { await recorder.openedSettings() },
        setBuiltinDisplayDimmed: { dimmed in await recorder.setDisplayDimmed(dimmed) },
        sleepDisplays: { await recorder.sleptDisplays() },
        lidChanges: { AsyncStream { $0.finish() } },
        statusChanges: { AsyncStream { $0.finish() } },
      )
      return store
    }
  }

}

// MARK: - KeepUnlockedPromptRecorder

private actor KeepUnlockedPromptRecorder {

  // MARK: Lifecycle

  init(choice: CaffeinateKeepUnlockedChoice) {
    self.choice = choice
  }

  // MARK: Internal

  struct Request: Equatable, Sendable {
    let includesOperationalSafety: Bool
    let autoLockEnabled: Bool
  }

  private(set) var requests = [Request]()

  func choose(
    includesOperationalSafety: Bool,
    autoLockEnabled: Bool,
  ) -> CaffeinateKeepUnlockedChoice {
    requests.append(
      Request(
        includesOperationalSafety: includesOperationalSafety,
        autoLockEnabled: autoLockEnabled,
      )
    )
    return choice
  }

  // MARK: Private

  private let choice: CaffeinateKeepUnlockedChoice

}

// MARK: - ClosedLidRecorder

private actor ClosedLidRecorder {
  struct Apply: Equatable, Sendable {
    let enabled: Bool
  }

  private(set) var applies = [Apply]()
  private(set) var displayDimmingStates = [Bool]()
  private(set) var displaySleepCount = 0
  private(set) var helperInstallCount = 0
  private(set) var helperRemovalCount = 0
  private(set) var settingsOpenCount = 0

  func applied(enabled: Bool) {
    applies.append(Apply(enabled: enabled))
  }

  func setDisplayDimmed(_ dimmed: Bool) -> BuiltinDisplayDimmingResult {
    displayDimmingStates.append(dimmed)
    return .applied
  }

  func sleptDisplays() -> DisplaySleepResult {
    displaySleepCount += 1
    return .applied
  }

  func removedHelper() -> PowerHelperInstallationStatus {
    helperRemovalCount += 1
    return .notInstalled
  }

  func installedHelper() -> PowerHelperInstallationStatus {
    helperInstallCount += 1
    return .installed(.current)
  }

  func openedSettings() {
    settingsOpenCount += 1
  }
}
