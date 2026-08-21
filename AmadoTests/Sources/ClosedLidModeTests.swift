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
    store.dependencies.closedLidControl.setEnabled = { enabled, registerIfNeeded in
      await recorder.applied(enabled: enabled, registerIfNeeded: registerIfNeeded)
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
    #expect(await recorder.applies == [.init(enabled: true, registerIfNeeded: true)])
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
  func `unlocked Caffeinate asks about auto-lock after the safety warning`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.proximityAutoLock = true
        $0.proximityDeviceID = Self.deviceID.uuidString
      }
    }
    let (choices, choiceContinuation) = AsyncStream<CaffeinateAutoLockPauseChoice>.makeStream()
    store.dependencies.caffeinatePrompt.askAutoLockPause = {
      await choices.first(where: { _ in true }) ?? .cancel
    }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateSafetyConfirmationFinished)
    choiceContinuation.yield(.pause)
    choiceContinuation.finish()
    await store.receive(\.caffeinateAutoLockPauseChoiceSelected) {
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
    #expect(await recorder.applies == [.init(enabled: true, registerIfNeeded: true)])
  }

  @Test
  func `switching awake policy keeps the existing helper lease`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }

    await store.send(.closedLidModeChanged(.unlocked)) {
      $0.$config.withLock { $0.closedLidMode = .unlocked }
      $0.appliedClosedLidMode = .unlocked
    }

    await store.finish()
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
    store.dependencies.caffeinatePrompt.askAutoLockPause = { .pause }

    await store.send(.closedLidModeChanged(.unlocked))

    await store.receive(\.caffeinateAutoLockPauseChoiceSelected) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = true
      }
      $0.appliedClosedLidMode = .unlocked
    }

    #expect(store.state.activeAutoLockPause == .whileCaffeinating)
    await store.finish()
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
    store.dependencies.caffeinatePrompt.askAutoLockPause = { .keepAutoLockOn }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateAutoLockPauseChoiceSelected) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.caffeinatePausesAutoLock = false
      }
      $0.appliedClosedLidMode = .unlocked
    }

    #expect(store.state.activeAutoLockPause == nil)
    await store.finish()
  }

  @Test
  func `cancelling the Caffeinate prompt preserves the current policy`() async {
    let recorder = ClosedLidRecorder()
    let store = makeStore(recorder) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.proximityAutoLock = true
      }
      $0.appliedClosedLidMode = .lock
      $0.closedLidStatus = .active
    }
    store.dependencies.caffeinatePrompt.askAutoLockPause = { .cancel }

    await store.send(.closedLidModeChanged(.unlocked))
    await store.receive(\.caffeinateAutoLockPauseChoiceSelected)

    #expect(store.state.config.closedLidMode == .lock)
    await store.finish()
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
    #expect(await recorder.applies == [.init(enabled: true, registerIfNeeded: false)])
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
    store.dependencies.closedLidControl.setEnabled = { _, _ in failure }

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
    store.dependencies.closedLidControl.setEnabled = { _, _ in .requiresApproval }
    store.dependencies.closedLidControl.openHelperSettings = { await recorder.openedSettings() }

    await store.send(.closedLidModeChanged(.lock))
    await store.receive(\.caffeinateSafetyConfirmationFinished) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.appliedClosedLidMode = .lock
      $0.isApplyingClosedLidMode = true
    }
    await store.receive(\.closedLidApplyResponse) {
      $0.closedLidStatus = .requiresApproval
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
      configure(&state)
      let store = TestStore(initialState: state) {
        AppFeature()
      }
      store.dependencies.notifier = NotifierClient(
        post: { _, _, _ in },
        withdraw: { _ in },
      )
      store.dependencies.caffeinatePrompt.confirmSafety = { true }
      store.dependencies.closedLidControl = ClosedLidControlClient(
        setEnabled: { enabled, registerIfNeeded in
          await recorder.applied(enabled: enabled, registerIfNeeded: registerIfNeeded)
          return enabled ? .active : .inactive
        },
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

// MARK: - ClosedLidRecorder

private actor ClosedLidRecorder {
  struct Apply: Equatable, Sendable {
    let enabled: Bool
    let registerIfNeeded: Bool
  }

  private(set) var applies = [Apply]()
  private(set) var displayDimmingStates = [Bool]()
  private(set) var displaySleepCount = 0
  private(set) var settingsOpenCount = 0

  func applied(enabled: Bool, registerIfNeeded: Bool) {
    applies.append(Apply(enabled: enabled, registerIfNeeded: registerIfNeeded))
  }

  func setDisplayDimmed(_ dimmed: Bool) -> BuiltinDisplayDimmingResult {
    displayDimmingStates.append(dimmed)
    return .applied
  }

  func sleptDisplays() -> DisplaySleepResult {
    displaySleepCount += 1
    return .applied
  }

  func openedSettings() {
    settingsOpenCount += 1
  }
}
