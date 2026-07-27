import Foundation
import Testing

@testable import AmadoKit

@Suite("Proximity decision engine")
struct ProximityDecisionEngineTests {

  // MARK: Internal

  @Test(
    arguments: [
      (ProximitySensitivity.fast, -56),
      (.balanced, -59),
      (.conservative, -63),
    ]
  )
  func `Smart sensitivity derives the expected adaptive threshold`(
    sensitivity: ProximitySensitivity,
    expectedThreshold: Int,
  ) {
    let result = makeArmedSmartEngine(sensitivity: sensitivity)

    #expect(result.engine.currentSnapshot.phase == .near)
    #expect(result.engine.currentSnapshot.learnedNearRSSI == -45)
    #expect(result.engine.currentSnapshot.farThresholdRSSI == expectedThreshold)
  }

  @Test
  func `Smart mode rejects a single RSSI spike`() {
    var result = makeArmedSmartEngine()
    let spike = result.engine.ingest(rssi: -100, at: result.time, idleSeconds: 20)
    result.time += 1

    #expect(spike.lockReason == nil)
    #expect(spike.snapshot.phase == .near)

    for _ in 0 ..< 8 {
      let evaluation = result.engine.ingest(rssi: -45, at: result.time, idleSeconds: 20)
      #expect(evaluation.lockReason == nil)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `Smart mode locks on a sustained departure trend`() {
    var result = makeArmedSmartEngine()
    var lockReason: ProximityDecisionEngine.LockReason?

    for rssi in [-50, -55, -60, -65, -70, -75, -80, -85, -85, -85, -85, -85, -85, -85, -85] {
      let evaluation = result.engine.ingest(rssi: rssi, at: result.time, idleSeconds: 20)
      lockReason = lockReason ?? evaluation.lockReason
      result.time += 1
    }

    #expect(lockReason != nil)
    #expect(result.engine.currentSnapshot.phase == .awayLatched)
  }

  @Test
  func `Recent Mac input suppresses a borderline weak signal`() {
    var result = makeArmedSmartEngine()
    var observedSuppression = false

    for rssi in [-50, -55, -60, -63, -64, -64, -64, -64, -64, -64] {
      let evaluation = result.engine.ingest(rssi: rssi, at: result.time, idleSeconds: 0)
      observedSuppression = observedSuppression || evaluation.snapshot.isActivitySuppressed
      #expect(evaluation.lockReason == nil)
      result.time += 1
    }

    #expect(observedSuppression)
    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `A very weak sustained signal overrides recent input`() {
    var result = makeArmedSmartEngine()
    var lockReason: ProximityDecisionEngine.LockReason?

    for _ in 0 ..< 24 {
      let evaluation = result.engine.ingest(rssi: -95, at: result.time, idleSeconds: 0)
      lockReason = lockReason ?? evaluation.lockReason
      result.time += 1
    }

    #expect(lockReason == .veryWeakSignal)
  }

  @Test
  func `Sudden strong-signal loss waits for the extended idle cap`() {
    var result = makeArmedSmartEngine()
    let firstLossCheck = result.engine.signalLost(at: result.time + 30, idleSeconds: 20)
    let extendedLossCheck = result.engine.signalLost(at: result.time + 90, idleSeconds: 20)

    #expect(firstLossCheck.lockReason == nil)
    #expect(firstLossCheck.snapshot.phase == .signalLost)
    #expect(extendedLossCheck.lockReason == .extendedSignalLoss)
  }

  @Test
  func `Signal loss after weakening confirms the departure`() {
    var result = makeArmedSmartEngine()

    for rssi in [-50, -55, -60, -65, -70, -75] {
      _ = result.engine.ingest(rssi: rssi, at: result.time, idleSeconds: 20)
      result.time += 1
    }
    let loss = result.engine.signalLost(at: result.time + 30, idleSeconds: 20)

    #expect(loss.lockReason == .signalLostAfterWeakening)
  }

  @Test
  func `Lifecycle reset preserves learning but requires stable re-arming`() {
    var result = makeArmedSmartEngine()
    let learned = result.engine.currentSnapshot.learnedNearRSSI
    result.engine.reset(clearLearnedBaseline: false)

    #expect(result.engine.currentSnapshot.phase == .learning)
    #expect(result.engine.currentSnapshot.learnedNearRSSI == learned)

    for _ in 0 ..< 4 {
      _ = result.engine.ingest(rssi: -45, at: result.time, idleSeconds: 0)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .learning)

    _ = result.engine.ingest(rssi: -45, at: result.time, idleSeconds: 0)
    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `Away latch re-arms only after a stable return`() {
    var result = makeArmedSmartEngine()
    for _ in 0 ..< 24 {
      _ = result.engine.ingest(rssi: -95, at: result.time, idleSeconds: 20)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .awayLatched)

    for _ in 0 ..< 4 {
      _ = result.engine.ingest(rssi: -42, at: result.time, idleSeconds: 0)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .awayLatched)

    for _ in 0 ..< 12 {
      _ = result.engine.ingest(rssi: -42, at: result.time, idleSeconds: 0)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `Manual mode preserves threshold and grace semantics`() {
    var engine = ProximityDecisionEngine(
      configuration: .init(
        mode: .manual,
        manualFarRSSI: -60,
        manualGraceSeconds: 2,
        manualSmoothing: 1,
      )
    )

    #expect(engine.ingest(rssi: -50, at: 0, idleSeconds: 0).lockReason == nil)
    #expect(engine.ingest(rssi: -70, at: 1, idleSeconds: 0).lockReason == nil)
    #expect(engine.ingest(rssi: -70, at: 2, idleSeconds: 0).lockReason == nil)
    #expect(engine.ingest(rssi: -70, at: 3, idleSeconds: 0).lockReason == .manualThreshold)
  }

  @Test
  func `Manual grace elapses without another RSSI sample`() {
    var engine = ProximityDecisionEngine(
      configuration: .init(
        mode: .manual,
        manualFarRSSI: -60,
        manualGraceSeconds: 2,
        manualSmoothing: 1,
      )
    )

    _ = engine.ingest(rssi: -50, at: 0, idleSeconds: 0)
    _ = engine.ingest(rssi: -70, at: 1, idleSeconds: 0)

    #expect(engine.advanceTime(to: 2.9, idleSeconds: 0).lockReason == nil)
    #expect(engine.advanceTime(to: 3, idleSeconds: 0).lockReason == .manualThreshold)
  }

  @Test
  func `Invalid Core Bluetooth RSSI sentinels are ignored`() {
    var engine = ProximityDecisionEngine(configuration: .init())

    let positive = engine.ingest(rssi: 127, at: 0, idleSeconds: 0)
    let tooWeak = engine.ingest(rssi: -127, at: 1, idleSeconds: 0)

    #expect(positive.snapshot.rssi == nil)
    #expect(tooWeak.snapshot.rssi == nil)
    #expect(engine.currentSnapshot.phase == .learning)
  }

  // MARK: Private

  private func makeArmedSmartEngine(
    sensitivity: ProximitySensitivity = .balanced
  ) -> (engine: ProximityDecisionEngine, time: TimeInterval) {
    var engine = ProximityDecisionEngine(
      configuration: .init(mode: .smart, sensitivity: sensitivity)
    )
    var time: TimeInterval = 0
    for _ in 0 ..< 12 {
      _ = engine.ingest(rssi: -45, at: time, idleSeconds: 0)
      time += 1
    }
    return (engine, time)
  }

}
