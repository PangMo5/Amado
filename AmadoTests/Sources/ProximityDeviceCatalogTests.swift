// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import Amado

@Suite("Proximity device catalog")
struct ProximityDeviceCatalogTests {

  // MARK: Internal

  @Test
  func `Continuity observations and paired devices coexist with distinct lifetimes`() {
    let now = Date(timeIntervalSince1970: 1_000)
    var catalog = ProximityDeviceCatalog()
    catalog.beginScan(pairedDevices: [Self.pixel, Self.watch])
    catalog.observeContinuity(
      id: Self.continuityID,
      name: "Nearby iPhone",
      rssi: -42,
      at: now,
    )

    #expect(catalog.nextNearbyExpiry(nearbyTTL: 5) == now.addingTimeInterval(5))

    #expect(
      catalog.snapshot(at: now, nearbyTTL: 5) == [
        DiscoveredDevice(id: .continuity(Self.continuityID), name: "Nearby iPhone", rssi: -42),
        Self.pixel,
        Self.watch,
      ]
    )
    #expect(
      catalog.snapshot(at: now.addingTimeInterval(6), nearbyTTL: 5) == [
        Self.pixel,
        Self.watch,
      ]
    )
    #expect(catalog.nextNearbyExpiry(nearbyTTL: 5) == nil)
  }

  @Test
  func `Refreshing paired devices replaces stale records and deduplicates identity`() {
    var catalog = ProximityDeviceCatalog()
    catalog.beginScan(pairedDevices: [Self.pixel, Self.watch])
    let renamedPixel = DiscoveredDevice(
      id: Self.pixel.id,
      name: "Pixel 10",
      rssi: nil,
    )

    catalog.replacePairedDevices([Self.pixel, renamedPixel])

    #expect(
      catalog.snapshot(at: Date(timeIntervalSince1970: 1_000), nearbyTTL: 5) == [renamedPixel]
    )
  }

  @Test
  func `Connected paired RSSI updates without mixing transport groups`() {
    let now = Date(timeIntervalSince1970: 1_000)
    var catalog = ProximityDeviceCatalog()
    catalog.beginScan(pairedDevices: [Self.pixel, Self.watch])
    catalog.observeContinuity(
      id: Self.continuityID,
      name: "Nearby iPhone",
      rssi: -70,
      at: now,
    )
    let connectedPixel = DiscoveredDevice(
      id: Self.pixel.id,
      name: Self.pixel.name,
      rssi: -30,
    )

    catalog.replacePairedDevices([connectedPixel, Self.watch])

    #expect(
      catalog.snapshot(at: now, nearbyTTL: 5) == [
        DiscoveredDevice(id: .continuity(Self.continuityID), name: "Nearby iPhone", rssi: -70),
        connectedPixel,
        Self.watch,
      ]
    )
  }

  @Test(arguments: [(-110, -110), (-1, -1), (-111, nil), (0, nil), (20, nil), (127, nil)])
  func `Continuity accepts only its negative RSSI range`(_ input: (value: Int, expected: Int?)) {
    #expect(ProximityRSSI.continuity(input.value) == input.expected)
  }

  @Test(arguments: [(-127, -110), (-111, -110), (-50, -50), (-1, -1), (0, nil), (20, -1), (127, nil)])
  func `Classic clamps documented values and rejects unusable sentinels`(
    _ input: (value: Int, expected: Int?)
  ) {
    #expect(ProximityRSSI.classic(input.value) == input.expected)
  }

  @Test
  func `Classic discovery exposes RSSI only for a live connection`() {
    #expect(ProximityRSSI.classic(-42, isConnected: true) == -42)
    #expect(ProximityRSSI.classic(-42, isConnected: false) == nil)
    #expect(ProximityRSSI.classic(0, isConnected: true) == nil)
  }

  @Test
  func `Classic callback identity accepts only the same live physical link`() {
    #expect(
      ClassicConnectionIdentity.matches(
        expected: 7,
        current: 7,
        isConnected: true,
      )
    )
    #expect(
      !ClassicConnectionIdentity.matches(
        expected: 7,
        current: 8,
        isConnected: true,
      )
    )
    #expect(
      !ClassicConnectionIdentity.matches(
        expected: 7,
        current: 7,
        isConnected: false,
      )
    )
    #expect(
      !ClassicConnectionIdentity.matches(
        expected: ClassicConnectionIdentity.none,
        current: ClassicConnectionIdentity.none,
        isConnected: true,
      )
    )
  }

  @Test
  func `Classic disconnect arms loss only after a usable sample on that link`() {
    var gate = ClassicSignalLossGate()

    gate.linkStarted()
    let disconnectedWithoutSample = gate.disconnected()
    #expect(!disconnectedWithoutSample)

    gate.linkStarted()
    gate.observedUsableRSSI()
    let armedDisconnect = gate.disconnected()
    let repeatedDisconnect = gate.disconnected()
    #expect(armedDisconnect)
    #expect(!repeatedDisconnect)

    gate.observedUsableRSSI()
    gate.linkStarted()
    let replacementDisconnect = gate.disconnected()
    #expect(!replacementDisconnect)
  }

  @Test
  func `Signal confirmation token rejects reconnect and lifecycle work`() {
    var coordinator = SignalCheckCoordinator()
    let disconnected = coordinator.arm(generation: 7)

    #expect(coordinator.accepts(disconnected, currentGeneration: 7))
    coordinator.cancel()
    #expect(!coordinator.accepts(disconnected, currentGeneration: 7))

    let replacement = coordinator.arm(generation: 7)
    #expect(!coordinator.accepts(disconnected, currentGeneration: 7))
    #expect(coordinator.accepts(replacement, currentGeneration: 7))
    #expect(!coordinator.accepts(replacement, currentGeneration: 8))
  }

  @Test
  func `Beginning a new scan removes stale Continuity observations`() {
    var catalog = ProximityDeviceCatalog()
    let now = Date(timeIntervalSince1970: 1_000)
    catalog.observeContinuity(
      id: Self.continuityID,
      name: "Old iPhone",
      rssi: -50,
      at: now,
    )

    catalog.beginScan(pairedDevices: [Self.pixel])

    #expect(catalog.snapshot(at: now, nearbyTTL: 5) == [Self.pixel])
  }

  @Test
  func `Classic completion is accepted only for its current successful attempt`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(coordinator.begin(generation: 8, address: attempt.address) == nil)
    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .useOwnedConnection
    )
  }

  @Test
  func `Successful stale Classic completion is adopted when the same address is current`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 8,
        currentAddress: attempt.address,
      ) == .useOwnedConnection
    )
  }

  @Test
  func `Successful stale Classic completion closes only a no-longer-selected address`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 8,
        currentAddress: "aa-bb-cc-dd-ee-00",
      ) == .closeStaleOwnedConnection
    )
  }

  @Test
  func `Failed Classic completion never claims a borrowed connected link`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.complete(
        attempt,
        succeeded: false,
        isConnected: true,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .retry
    )
  }

  @Test
  func `Classic watchdog retires a lost callback and permits another attempt`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.timeOut(
        attempt,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .retry
    )
    #expect(coordinator.tracks(attemptID: attempt.id))
    #expect(coordinator.begin(generation: 8, address: attempt.address) != nil)
    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 8,
        currentAddress: attempt.address,
      ) == .useOwnedConnection
    )
    #expect(!coordinator.tracks(attemptID: attempt.id))
  }

  @Test
  func `Classic watchdog never claims a link without a success callback`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.timeOut(
        attempt,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .retry
    )
    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .useOwnedConnection
    )
  }

  @Test
  func `Late successful Classic completion cleans up a removed selection`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.timeOut(
        attempt,
        currentGeneration: 8,
        currentAddress: nil,
      ) == .ignore
    )
    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 8,
        currentAddress: nil,
      ) == .closeStaleOwnedConnection
    )
  }

  @Test
  func `Classic completion followed by an already queued watchdog is idempotent`() throws {
    var coordinator = ClassicConnectionCoordinator()
    let pending = coordinator.begin(generation: 7, address: "aa-bb-cc-dd-ee-ff")
    let attempt = try #require(pending)

    #expect(
      coordinator.complete(
        attempt,
        succeeded: true,
        isConnected: true,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .useOwnedConnection
    )
    #expect(
      coordinator.timeOut(
        attempt,
        currentGeneration: 7,
        currentAddress: attempt.address,
      ) == .ignore
    )
  }

  @Test
  func `Classic link epoch rejects an old disconnect after reconnect`() {
    var coordinator = ClassicLinkCoordinator()
    let first = coordinator.activate(
      generation: 7,
      address: "aa-bb-cc-dd-ee-ff",
      handle: 1,
    )

    let firstDisconnected = coordinator.disconnect(first)
    #expect(firstDisconnected)
    let second = coordinator.activate(
      generation: 7,
      address: first.address,
      handle: 2,
    )

    let staleDisconnectAccepted = coordinator.disconnect(first)
    #expect(!staleDisconnectAccepted)
    #expect(!coordinator.accepts(first))
    #expect(coordinator.accepts(second))
  }

  @Test
  func `Invalidating a Classic link rejects delayed poll work`() {
    var coordinator = ClassicLinkCoordinator()
    let link = coordinator.activate(
      generation: 7,
      address: "aa-bb-cc-dd-ee-ff",
      handle: 1,
    )

    coordinator.invalidate()

    #expect(!coordinator.accepts(link))
  }

  // MARK: Private

  private static let continuityID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000123"
  )!
  private static let pixel = DiscoveredDevice(
    id: .classic("aa-bb-cc-dd-ee-01"),
    name: "Pixel",
    rssi: nil,
  )
  private static let watch = DiscoveredDevice(
    id: .classic("aa-bb-cc-dd-ee-02"),
    name: "Watch",
    rssi: nil,
  )

}
