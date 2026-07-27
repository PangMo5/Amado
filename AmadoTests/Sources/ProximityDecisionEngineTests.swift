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
    let spike = result.engine.ingest(rssi: -100, at: result.time)
    result.time += 1

    #expect(spike.lockReason == nil)
    #expect(spike.snapshot.phase == .near)

    for _ in 0 ..< 8 {
      let evaluation = result.engine.ingest(rssi: -45, at: result.time)
      #expect(evaluation.lockReason == nil)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `Smart mode rejects two consecutive very weak readings`() {
    var result = makeArmedSmartEngine()

    #expect(result.engine.ingest(rssi: -100, at: result.time).lockReason == nil)
    result.time += 1
    #expect(result.engine.ingest(rssi: -100, at: result.time).lockReason == nil)
    result.time += 1
    #expect(result.engine.ingest(rssi: -45, at: result.time).lockReason == nil)

    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `Strong nearby peaks do not turn normal nearby fading into departure`() {
    var result = makeArmedSmartEngine(nearbyRSSI: -52)

    #expect(result.engine.currentSnapshot.learnedNearRSSI == -52)
    #expect(result.engine.currentSnapshot.farThresholdRSSI == -66)

    for _ in 0 ..< 90 {
      #expect(result.engine.ingest(rssi: -38, at: result.time).lockReason == nil)
      result.time += 1
    }

    #expect(result.engine.currentSnapshot.learnedNearRSSI == -52)
    #expect(result.engine.currentSnapshot.farThresholdRSSI == -66)

    let nearbyFade = [-48, -52, -55, -57, -53, -55, -53, -55, -52, -50, -45, -42]
    for rssi in nearbyFade {
      #expect(result.engine.ingest(rssi: rssi, at: result.time).lockReason == nil)
      result.time += 1
    }

    #expect(result.engine.currentSnapshot.phase == .near)
    let signalLoss = result.engine.signalLost(at: result.time + 30)
    #expect(signalLoss.lockReason == nil)
  }

  @Test
  func `Strong initial readings cannot create an unsafe Smart threshold`() {
    var result = makeArmedSmartEngine(nearbyRSSI: -38)

    #expect(result.engine.currentSnapshot.learnedNearRSSI == -45)
    #expect(result.engine.currentSnapshot.farThresholdRSSI == -59)

    for _ in 0 ..< 90 {
      #expect(result.engine.ingest(rssi: -53, at: result.time).lockReason == nil)
      result.time += 1
    }

    #expect(result.engine.currentSnapshot.phase == .near)
    #expect(result.engine.currentSnapshot.learnedNearRSSI == -49)
    #expect(result.engine.currentSnapshot.farThresholdRSSI == -63)
  }

  @Test
  func `Gradual departure cannot be learned as nearby indefinitely`() {
    var result = makeArmedSmartEngine(nearbyRSSI: -52)
    var lockReason: ProximityDecisionEngine.LockReason?

    for rssi in stride(from: -53, through: -85, by: -1) {
      for _ in 0 ..< 24 {
        let evaluation = result.engine.ingest(rssi: rssi, at: result.time)
        lockReason = lockReason ?? evaluation.lockReason
        result.time += 1
      }
    }

    #expect(lockReason != nil)
    #expect(result.engine.currentSnapshot.learnedNearRSSI == -56)
    #expect(result.engine.currentSnapshot.farThresholdRSSI == -70)
  }

  @Test
  func `Smart mode locks quickly when independent evidence agrees`() {
    var result = makeArmedSmartEngine()
    var lockReason: ProximityDecisionEngine.LockReason?
    var samplesUntilLock: Int?

    for (offset, rssi) in [-75, -82, -88, -92, -95].enumerated() {
      let evaluation = result.engine.ingest(rssi: rssi, at: result.time)
      lockReason = lockReason ?? evaluation.lockReason
      if evaluation.lockReason != nil {
        samplesUntilLock = offset + 1
        break
      }
      result.time += 1
    }

    #expect(lockReason == .veryWeakSignal)
    #expect(samplesUntilLock != nil)
    #expect((samplesUntilLock ?? .max) <= 4)
    #expect(result.engine.currentSnapshot.phase == .awayLatched)
  }

  @Test
  func `Smart mode still confirms a sustained borderline departure`() {
    var result = makeArmedSmartEngine()
    var lockReason: ProximityDecisionEngine.LockReason?

    for rssi in [-50, -55, -60, -63, -64, -64, -64, -64, -64, -64, -64, -64] {
      let evaluation = result.engine.ingest(rssi: rssi, at: result.time)
      lockReason = lockReason ?? evaluation.lockReason
      result.time += 1
    }

    #expect(lockReason == .weakSignalTrend)
    #expect(result.engine.currentSnapshot.phase == .awayLatched)
  }

  @Test
  func `A very weak sustained signal locks without user activity input`() {
    var result = makeArmedSmartEngine()
    var lockReason: ProximityDecisionEngine.LockReason?

    for _ in 0 ..< 24 {
      let evaluation = result.engine.ingest(rssi: -95, at: result.time)
      lockReason = lockReason ?? evaluation.lockReason
      result.time += 1
    }

    #expect(lockReason == .veryWeakSignal)
  }

  @Test
  func `Sudden strong-signal loss locks at the extended cap without an activity override`() {
    var result = makeArmedSmartEngine()
    let firstLossCheck = result.engine.signalLost(at: result.time + 30)
    let extendedLossCheck = result.engine.signalLost(at: result.time + 90)

    #expect(firstLossCheck.lockReason == nil)
    #expect(firstLossCheck.snapshot.phase == .signalLost)
    #expect(extendedLossCheck.lockReason == .extendedSignalLoss)
  }

  @Test
  func `Signal loss after weakening confirms the departure`() {
    var result = makeArmedSmartEngine()

    for rssi in [-50, -55, -60, -65, -70, -75] {
      _ = result.engine.ingest(rssi: rssi, at: result.time)
      result.time += 1
    }
    let loss = result.engine.signalLost(at: result.time + 30)

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
      _ = result.engine.ingest(rssi: -45, at: result.time)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .learning)

    _ = result.engine.ingest(rssi: -45, at: result.time)
    #expect(result.engine.currentSnapshot.phase == .near)
  }

  @Test
  func `Away latch re-arms only after a stable return`() {
    var result = makeArmedSmartEngine()
    for _ in 0 ..< 24 {
      _ = result.engine.ingest(rssi: -95, at: result.time)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .awayLatched)

    for _ in 0 ..< 4 {
      _ = result.engine.ingest(rssi: -42, at: result.time)
      result.time += 1
    }
    #expect(result.engine.currentSnapshot.phase == .awayLatched)

    for _ in 0 ..< 12 {
      _ = result.engine.ingest(rssi: -42, at: result.time)
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

    #expect(engine.ingest(rssi: -50, at: 0).lockReason == nil)
    #expect(engine.ingest(rssi: -70, at: 1).lockReason == nil)
    #expect(engine.ingest(rssi: -70, at: 2).lockReason == nil)
    #expect(engine.ingest(rssi: -70, at: 3).lockReason == .manualThreshold)
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

    _ = engine.ingest(rssi: -50, at: 0)
    _ = engine.ingest(rssi: -70, at: 1)

    #expect(engine.advanceTime(to: 2.9).lockReason == nil)
    #expect(engine.advanceTime(to: 3).lockReason == .manualThreshold)
  }

  @Test
  func `Invalid Core Bluetooth RSSI sentinels are ignored`() {
    var engine = ProximityDecisionEngine(configuration: .init())

    let positive = engine.ingest(rssi: 127, at: 0)
    let tooWeak = engine.ingest(rssi: -127, at: 1)

    #expect(positive.snapshot.rssi == nil)
    #expect(tooWeak.snapshot.rssi == nil)
    #expect(engine.currentSnapshot.phase == .learning)
  }

  // MARK: Private

  private func makeArmedSmartEngine(
    sensitivity: ProximitySensitivity = .balanced,
    nearbyRSSI: Int = -45,
  ) -> (engine: ProximityDecisionEngine, time: TimeInterval) {
    var engine = ProximityDecisionEngine(
      configuration: .init(mode: .smart, sensitivity: sensitivity)
    )
    var time: TimeInterval = 0
    for _ in 0 ..< 12 {
      _ = engine.ingest(rssi: nearbyRSSI, at: time)
      time += 1
    }
    return (engine, time)
  }

}
