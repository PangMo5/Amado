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
    #expect(decoded.macID.isEmpty)
  }
}
