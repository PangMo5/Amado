// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing
import Testing

@testable import Amado

// MARK: - AgentHealthTests

@MainActor
@Suite("Agent health")
struct AgentHealthTests {

  // MARK: Internal

  @Test
  func `raises and clears the LAN listener issue`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)

    await store.send(.lanListenerStateChanged(.unavailable(reason: "Address already in use"))) {
      $0.issues = [AgentIssue(kind: .lanListener, detail: "Address already in use")]
    }
    #expect(store.state.health == .impaired(AgentIssue(kind: .lanListener, detail: "Address already in use")))

    await store.send(.lanListenerStateChanged(.ready)) {
      $0.isListening = true
      $0.issues = []
    }
    #expect(store.state.health == .listening)

    await store.finish()
    #expect(await notifications.posted == ["lanListener"])
    #expect(await notifications.withdrawn == ["lanListener"])
  }

  @Test
  func `closed-lid awake mode becomes the healthy menu bar state`() async {
    let store = makeStore(NotificationRecorder()) {
      $0.$config.withLock { $0.closedLidMode = .lock }
      $0.closedLidStatus = .active
      $0.isListening = true
    }

    #expect(
      store.state.health == .closedLidAwake(
        policy: .lockOnClose,
        autoLockPause: nil,
      )
    )

    await store.send(.lanListenerStateChanged(.unavailable(reason: "Port busy"))) {
      $0.isListening = false
      $0.issues = [AgentIssue(kind: .lanListener, detail: "Port busy")]
    }
    #expect(store.state.health == .impaired(AgentIssue(kind: .lanListener, detail: "Port busy")))

    await store.finish()
  }

  @Test
  func `closed-lid health preserves lock policy and auto-lock pause`() async {
    let deadline = Date(timeIntervalSince1970: 2_000)
    let lockedStore = makeStore(NotificationRecorder()) {
      $0.$config.withLock {
        $0.closedLidMode = .lock
        $0.proximityAutoLock = true
        $0.proximityDeviceID = UUID().uuidString
        $0.proximityPauseUntil = deadline.timeIntervalSince1970
      }
      $0.closedLidStatus = .active
      $0.isListening = true
    }
    let unlockedStore = makeStore(NotificationRecorder()) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.proximityAutoLock = true
        $0.proximityDeviceID = UUID().uuidString
        $0.proximityPauseUntil = deadline.timeIntervalSince1970
      }
      $0.closedLidStatus = .active
      $0.isListening = true
    }

    #expect(
      lockedStore.state.health == .closedLidAwake(
        policy: .lockOnClose,
        autoLockPause: .until(deadline),
      )
    )
    #expect(
      unlockedStore.state.health == .closedLidAwake(
        policy: .keepUnlocked,
        autoLockPause: .until(deadline),
      )
    )

    await lockedStore.finish()
    await unlockedStore.finish()
  }

  @Test
  func `menu bar indicator keeps auto-lock closed-lid and pause meanings independent`() async {
    let deadline = Date(timeIntervalSince1970: 2_000)

    for isAutoLockEnabled in [false, true] {
      for closedLidMode in ClosedLidMode.allCases {
        for isPauseConfigured in [false, true] {
          for caffeinatePausesAutoLock in [false, true] {
            let store = makeStore(NotificationRecorder()) {
              $0.$config.withLock {
                $0.closedLidMode = closedLidMode
                $0.proximityAutoLock = isAutoLockEnabled
                $0.proximityDeviceID = UUID().uuidString
                $0.caffeinatePausesAutoLock = caffeinatePausesAutoLock
                $0.proximityPauseUntil = isPauseConfigured
                  ? deadline.timeIntervalSince1970
                  : nil
              }
              $0.closedLidStatus = closedLidMode == .off ? .inactive : .active
            }

            #expect(
              store.state.menuBarIndicator == MenuBarIndicatorState(
                isAutoLockEnabled: isAutoLockEnabled,
                closedLidPolicy: closedLidMode.awakePolicy,
                isAutoLockPaused: isAutoLockEnabled
                  && (
                    isPauseConfigured
                      || (closedLidMode == .unlocked && caffeinatePausesAutoLock)
                  ),
                needsAttention: false,
              )
            )

            await store.finish()
          }
        }
      }
    }
  }

  @Test
  func `attention marker does not replace the other menu bar meanings`() async {
    let deadline = Date(timeIntervalSince1970: 2_000)
    let store = makeStore(NotificationRecorder()) {
      $0.$config.withLock {
        $0.closedLidMode = .unlocked
        $0.proximityAutoLock = true
        $0.proximityDeviceID = UUID().uuidString
        $0.proximityPauseUntil = deadline.timeIntervalSince1970
      }
      $0.closedLidStatus = .active
      $0.issues = [AgentIssue(kind: .lanListener, detail: "Port busy")]
    }

    #expect(
      store.state.menuBarIndicator == MenuBarIndicatorState(
        isAutoLockEnabled: true,
        closedLidPolicy: .keepUnlocked,
        isAutoLockPaused: true,
        needsAttention: true,
      )
    )

    await store.finish()
  }

  @Test
  func `a retrying listener notifies once, not once per attempt`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)

    await store.send(.lanListenerStateChanged(.unavailable(reason: "Address already in use"))) {
      $0.issues = [AgentIssue(kind: .lanListener, detail: "Address already in use")]
    }
    // The same failure arriving again is the backoff at work, not news.
    await store.send(.lanListenerStateChanged(.unavailable(reason: "Address already in use")))

    await store.finish()
    #expect(await notifications.posted == ["lanListener"])
  }

  @Test
  func `keeps the worst issue first`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)

    await store.send(.remoteListenerStateChanged(.stopped(reason: "Server stopped"))) {
      $0.issues = [AgentIssue(kind: .remoteListener, detail: "Server stopped")]
    }
    await store.send(.lanListenerStateChanged(.unavailable(reason: "Port busy"))) {
      $0.issues = [
        AgentIssue(kind: .lanListener, detail: "Port busy"),
        AgentIssue(kind: .remoteListener, detail: "Server stopped"),
      ]
    }
    #expect(store.state.issues.first?.kind == .lanListener)

    await store.finish()
    // The remote listener is degraded, not broken, so it stays out of the way.
    #expect(await notifications.posted == ["lanListener"])
  }

  @Test
  func `reports a screen lock that cannot run`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)

    await store.send(.screenLockAttempted(succeeded: false)) {
      $0.issues = [
        AgentIssue(
          kind: .screenLock,
          detail: "This version of macOS no longer exposes the lock entry point Amado uses.",
        )
      ]
    }
    await store.send(.screenLockAttempted(succeeded: true)) {
      $0.issues = []
    }

    await store.finish()
    #expect(await notifications.posted == ["screenLock"])
    #expect(await notifications.withdrawn == ["screenLock"])
  }

  @Test
  func `reports Bluetooth only once auto-lock depends on it`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)

    // Auto-lock is off, so the radio being off is nobody's problem.
    await store.send(.proximityStatusChanged(.waitingForBluetooth(.poweredOff))) {
      $0.proximityStatus = .waitingForBluetooth(.poweredOff)
    }
    #expect(store.state.issues.isEmpty)

    store.state.$config.withLock {
      $0.proximityAutoLock = true
      $0.proximityDeviceID = UUID().uuidString
    }
    await store.send(.proximityStatusChanged(.waitingForBluetooth(.poweredOff))) {
      $0.issues = [
        AgentIssue(
          kind: .bluetooth,
          detail: BluetoothUnavailability.poweredOff.summary,
          recovery: SystemSettings.bluetooth.map(AgentIssueRecovery.openSettings),
        )
      ]
    }

    await store.finish()
    #expect(await notifications.posted == ["bluetooth"])
  }

  @Test
  func `stays quiet while Bluetooth restarts itself`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)
    store.state.$config.withLock {
      $0.proximityAutoLock = true
      $0.proximityDeviceID = UUID().uuidString
    }

    await store.send(.proximityStatusChanged(.waitingForBluetooth(.resetting))) {
      $0.proximityStatus = .waitingForBluetooth(.resetting)
      $0.issues = [
        AgentIssue(kind: .bluetooth, detail: BluetoothUnavailability.resetting.summary)
      ]
    }

    await store.finish()
    // Visible in the menu, but not worth a notification: it fixes itself.
    #expect(await notifications.posted.isEmpty)
  }

  @Test
  func `reports a login item macOS refused`() async {
    let notifications = NotificationRecorder()
    let store = makeStore(notifications)

    await store.send(.loginItemChanged(failure: "Operation not permitted")) {
      $0.issues = [AgentIssue(kind: .loginItem, detail: "Operation not permitted")]
    }
    await store.send(.loginItemChanged(failure: nil)) {
      $0.issues = []
    }

    await store.finish()
    // A login item that did not take is worth showing, not interrupting for.
    #expect(await notifications.posted.isEmpty)
    #expect(await notifications.withdrawn == ["loginItem"])
  }

  // MARK: Private

  private func makeStore(
    _ recorder: NotificationRecorder,
    updateState: (inout AppFeature.State) -> Void = { _ in },
  ) -> TestStoreOf<AppFeature> {
    withDependencies {
      // Keep the shared config and pairing registry off the developer's disk.
      $0.defaultFileStorage = .inMemory
    } operation: {
      var state = AppFeature.State()
      updateState(&state)
      let store = TestStore(initialState: state) {
        AppFeature()
      }
      store.dependencies.notifier = NotifierClient(
        post: { id, _, _ in await recorder.post(id) },
        withdraw: { id in await recorder.withdraw(id) },
      )
      return store
    }
  }

}

// MARK: - NotificationRecorder

private actor NotificationRecorder {
  var posted = [String]()
  var withdrawn = [String]()

  func post(_ id: String) {
    posted.append(id)
  }

  func withdraw(_ id: String) {
    withdrawn.append(id)
  }
}
