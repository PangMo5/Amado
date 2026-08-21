// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
import TOML

@testable import Amado

@Suite("Amado config")
struct AmadoConfigTests {
  @Test
  func `Pause deadline is active only before its stored instant`() {
    let deadline = Date(timeIntervalSince1970: 2_000)
    let config = AmadoConfig(proximityPauseUntil: deadline.timeIntervalSince1970)

    #expect(
      config.activeProximityPauseUntil(at: Date(timeIntervalSince1970: 1_999))
        == deadline
    )
    #expect(
      config.activeProximityPauseUntil(at: deadline) == nil
    )
  }

  @Test
  func `Pause deadline round trips through TOML`() throws {
    let expected = AmadoConfig(
      macID: UUID().uuidString,
      proximityAutoLock: true,
      caffeinatePausesAutoLock: true,
      proximityPauseUntil: 2_000,
      proximityDeviceID: UUID().uuidString,
    )
    let encoder = TOMLEncoder()
    let encoded = try encoder.encode(expected)

    let decoded = try TOMLDecoder().decode(AmadoConfig.self, from: encoded)

    #expect(decoded == expected)
  }

  @Test
  func `Existing config without pause deadline remains unpaused`() throws {
    let decoded = try TOMLDecoder().decode(
      AmadoConfig.self,
      from: """
        proximity_auto_lock = true
        proximity_mode = "smart"
        """,
    )

    #expect(decoded.proximityPauseUntil == nil)
    #expect(decoded.caffeinatePausesAutoLock == false)
    #expect(decoded.macID.isEmpty)
    #expect(decoded.closedLidMode == .off)
  }

  @Test(arguments: ClosedLidMode.allCases)
  func `Closed lid mode round trips through TOML`(_ mode: ClosedLidMode) throws {
    let expected = AmadoConfig(closedLidMode: mode)

    let encoded = try TOMLEncoder().encode(expected)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    let decoded = try TOMLDecoder().decode(AmadoConfig.self, from: encoded)

    #expect(encodedText.contains("caffeinate_mode"))
    #expect(!encodedText.contains("closed_lid_mode"))
    #expect(decoded == expected)
  }

  @Test
  func `Unreleased closed lid config key is not accepted as Caffeinate mode`() throws {
    let decoded = try TOMLDecoder().decode(
      AmadoConfig.self,
      from: "closed_lid_mode = \"unlocked\"",
    )

    #expect(decoded.closedLidMode == .off)
  }

  @Test
  func `Caffeinate auto-lock pause follows only the unlocked policy`() {
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(
      AmadoConfig(
        closedLidMode: .unlocked,
        caffeinatePausesAutoLock: true,
      ).activeAutoLockPause(at: now) == .whileCaffeinating
    )
    #expect(
      AmadoConfig(
        closedLidMode: .lock,
        caffeinatePausesAutoLock: true,
      ).activeAutoLockPause(at: now) == nil
    )
  }
}
