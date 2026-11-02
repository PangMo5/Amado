// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing
import Testing

@testable import Amado

@MainActor
@Suite("Proximity selection")
struct ProximitySelectionTests {

  // MARK: Internal

  @Test
  func `Selecting a Continuity device persists its qualified identity`() async {
    await assertSelection(Self.continuityDevice)
  }

  @Test
  func `Selecting a Classic device persists its qualified identity`() async {
    await assertSelection(Self.classicDevice)
  }

  @Test
  func `Far events from another device or monitor session cannot lock`() async {
    let store = makeStore {
      $0.$config.withLock {
        $0.proximityAutoLock = true
        $0.proximityDeviceTransport = .classic
        $0.proximityDeviceID = Self.classicAddress
        $0.proximityDeviceName = "Pixel"
      }
      $0.proximityMonitorSession = 2
    }
    store.dependencies.screenLocker.lock = {
      Issue.record("A stale device event must not reach the screen locker")
      return true
    }

    await store.send(
      .proximityFarDetected(
        ProximityFarEvent(
          device: .continuity(Self.continuityID),
          session: 2,
          reason: .veryWeakSignal,
        )
      )
    )
    await store.send(
      .proximityFarDetected(
        ProximityFarEvent(
          device: .classic(Self.classicAddress),
          session: 1,
          reason: .veryWeakSignal,
        )
      )
    )

    await store.finish()
  }

  @Test
  func `Status events from a previous monitor session are ignored`() async {
    let store = makeStore {
      $0.$config.withLock {
        $0.proximityAutoLock = true
        $0.proximityDeviceTransport = .classic
        $0.proximityDeviceID = Self.classicAddress
      }
      $0.proximityMonitorSession = 2
      $0.proximityStatus = .searching
    }

    await store.send(
      .proximityStatusChanged(
        ProximityStatusEvent(
          device: .classic(Self.classicAddress),
          session: 1,
          status: .connectionUnavailable,
        )
      )
    )

    await store.finish()
  }

  @Test
  func `A matching selected Classic far event can lock`() async {
    let store = makeStore {
      $0.$config.withLock {
        $0.proximityAutoLock = true
        $0.proximityDeviceTransport = .classic
        $0.proximityDeviceID = Self.classicAddress
        $0.proximityDeviceName = "Pixel"
      }
    }
    store.dependencies.screenLocker.lock = { true }

    await store.send(
      .proximityFarDetected(
        ProximityFarEvent(
          device: .classic(Self.classicAddress),
          session: 0,
          reason: .weakSignalTrend,
        )
      )
    ) {
      $0.activity = [
        ActivityEntry(
          id: Self.eventID,
          at: Self.now,
          message: "Locked — Pixel left (weakening signal)",
          kind: .locked,
        )
      ]
    }
    await store.receive(\.screenLockAttempted)

    await store.finish()
  }

  @Test
  func `Changing transport reapplies the typed monitor configuration`() async {
    let config = AmadoConfig(
      proximityAutoLock: true,
      proximityDeviceTransport: .classic,
      proximityDeviceID: Self.classicAddress,
      proximityDeviceName: "Pixel",
    )
    let monitored = LockIsolated<[ProximityMonitorConfiguration]>([])
    let store = makeStore {
      $0.$config.withLock { $0 = config }
      $0.appliedProximityKey =
        "true||off|false|continuity|\(Self.classicAddress)|smart|balanced|-56|2.0|3"
    }
    store.dependencies.proximityLock.monitor = { configuration in
      monitored.withValue { $0.append(configuration) }
    }

    await store.send(.configChanged(config)) {
      $0.appliedProximityKey =
        "true||off|false|classic|\(Self.classicAddress)|smart|balanced|-56|2.0|3"
      $0.appliedProximityDevice = .classic(Self.classicAddress)
      $0.proximityMonitorSession = 1
      $0.proximityStatus = .searching
    }

    await store.finish()
    #expect(
      monitored.value == [
        ProximityMonitorConfiguration(
          device: .classic(Self.classicAddress),
          session: 1,
          mode: .smart,
          sensitivity: .balanced,
          manualFarRSSI: -56,
          manualGraceSeconds: 2,
          manualSmoothing: 3,
        )
      ]
    )
  }

  @Test
  func `Disabled Classic configuration applies a nil monitor target`() async {
    let config = AmadoConfig(
      proximityDeviceTransport: .classic,
      proximityDeviceID: Self.classicAddress,
      proximityDeviceName: "Pixel",
    )
    let monitored = LockIsolated<[ProximityMonitorConfiguration]>([])
    let store = makeStore {
      $0.$config.withLock { $0 = config }
    }
    store.dependencies.proximityLock.monitor = { configuration in
      monitored.withValue { $0.append(configuration) }
    }

    await store.send(.configChanged(config)) {
      $0.appliedProximityKey =
        "false||off|false|classic|\(Self.classicAddress)|smart|balanced|-56|2.0|3"
      $0.proximityMonitorSession = 1
    }

    await store.finish()
    #expect(monitored.value.count == 1)
    #expect(monitored.value.first?.device == nil)
    #expect(monitored.value.first?.session == 1)
  }

  @Test
  func `Unchanged proximity configuration does not restart monitoring`() async {
    let config = AmadoConfig(
      proximityDeviceTransport: .classic,
      proximityDeviceID: Self.classicAddress,
    )
    let store = makeStore {
      $0.$config.withLock { $0 = config }
      $0.appliedProximityKey =
        "false||off|false|classic|\(Self.classicAddress)|smart|balanced|-56|2.0|3"
    }
    store.dependencies.proximityLock.monitor = { _ in
      Issue.record("An unchanged configuration must not restart proximity monitoring")
    }

    await store.send(.configChanged(config))

    await store.finish()
  }

  @Test
  func `Scan lifecycle starts once and clears devices when stopped`() async {
    let starts = LockIsolated(0)
    let stops = LockIsolated(0)
    let store = makeStore {
      $0.proximityDevices = [Self.classicDevice]
    }
    store.dependencies.proximityLock.startScanning = {
      starts.withValue { $0 += 1 }
    }
    store.dependencies.proximityLock.stopScanning = {
      stops.withValue { $0 += 1 }
    }

    await store.send(.proximityScanToggled(true))
    await store.send(.proximityScanToggled(false)) {
      $0.proximityDevices = []
    }

    await store.finish()
    #expect(starts.value == 1)
    #expect(stops.value == 1)
  }

  // MARK: Private

  private static let classicAddress = "aa-bb-cc-dd-ee-ff"
  private static let continuityID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000123"
  )!
  private static let eventID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000456"
  )!
  private static let now = Date(timeIntervalSince1970: 1_000)
  private static let continuityDevice = DiscoveredDevice(
    id: .continuity(continuityID),
    name: "iPhone",
    rssi: -40,
  )
  private static let classicDevice = DiscoveredDevice(
    id: .classic(classicAddress),
    name: "Pixel",
    rssi: nil,
  )

  private func assertSelection(_ device: DiscoveredDevice) async {
    let store = makeStore()

    await store.send(.proximityDeviceSelected(device)) {
      $0.$config.withLock {
        $0.proximityDeviceTransport = device.id.transport
        $0.proximityDeviceID = device.id.rawValue
        $0.proximityDeviceName = device.name
      }
    }

    await store.finish()
  }

  private func makeStore(
    configure: (inout AppFeature.State) -> Void = { _ in }
  ) -> TestStoreOf<AppFeature> {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.date = .constant(Self.now)
      $0.uuid = .constant(Self.eventID)
    } operation: {
      var state = AppFeature.State()
      configure(&state)
      return TestStore(initialState: state) {
        AppFeature()
      }
    }
  }

}
