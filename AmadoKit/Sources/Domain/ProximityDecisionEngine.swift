import Foundation

// MARK: - ProximityDetectionMode

/// How Amado decides that the monitored iPhone left.
public enum ProximityDetectionMode: String, CaseIterable, Codable, Hashable, Sendable {
  /// Learns the nearby signal and combines robust RSSI filtering, its trend,
  /// recent Mac input, and signal-loss context.
  case smart
  /// Uses the user-provided RSSI threshold, grace, and moving-average window.
  case manual
}

// MARK: - ProximitySensitivity

/// User-facing presets for smart proximity detection.
public enum ProximitySensitivity: String, CaseIterable, Codable, Hashable, Sendable {
  case conservative
  case balanced
  case fast
}

// MARK: - ProximityDecisionEngine

/// A deterministic, platform-independent proximity state machine.
///
/// Core Bluetooth and macOS lifecycle code feed timestamped observations into
/// this value. Keeping the decision logic free of timers and framework state
/// makes recorded RSSI sequences cheap and reliable to test.
public struct ProximityDecisionEngine: Sendable {

  // MARK: Lifecycle

  public init(configuration: Configuration) {
    self.configuration = configuration.normalized
    armed = configuration.mode == .manual
  }

  // MARK: Public

  public struct Configuration: Equatable, Sendable {

    // MARK: Lifecycle

    public init(
      mode: ProximityDetectionMode = .smart,
      sensitivity: ProximitySensitivity = .balanced,
      manualFarRSSI: Int = -56,
      manualGraceSeconds: TimeInterval = 2,
      manualSmoothing: Int = 3,
    ) {
      self.mode = mode
      self.sensitivity = sensitivity
      self.manualFarRSSI = manualFarRSSI
      self.manualGraceSeconds = manualGraceSeconds
      self.manualSmoothing = manualSmoothing
    }

    // MARK: Public

    public var mode: ProximityDetectionMode
    public var sensitivity: ProximitySensitivity
    public var manualFarRSSI: Int
    public var manualGraceSeconds: TimeInterval
    public var manualSmoothing: Int

    // MARK: Fileprivate

    fileprivate var normalized: Self {
      var copy = self
      copy.manualFarRSSI = min(-40, max(-90, manualFarRSSI))
      copy.manualGraceSeconds = min(30, max(0, manualGraceSeconds))
      copy.manualSmoothing = min(20, max(1, manualSmoothing))
      return copy
    }

  }

  public enum Phase: String, Equatable, Sendable {
    /// Collecting enough stable nearby observations to arm.
    case learning
    case near
    case suspectedAway
    /// Bluetooth is powered on, but no usable RSSI has arrived recently.
    case signalLost
    /// A lock fired; another lock is impossible until stable proximity returns.
    case awayLatched
  }

  public enum LockReason: String, Equatable, Sendable {
    case weakSignalTrend
    case veryWeakSignal
    case signalLostAfterWeakening
    case extendedSignalLoss
    case manualThreshold
    case manualSignalLoss
  }

  public struct Snapshot: Equatable, Sendable {
    public let phase: Phase
    public let rssi: Int?
    public let learnedNearRSSI: Int?
    public let farThresholdRSSI: Int?
    public let slope: Double?
    public let idleSeconds: TimeInterval
    public let isActivitySuppressed: Bool
    public let secondsUntilLock: Int?
    public let lockReason: LockReason?
  }

  public struct Evaluation: Equatable, Sendable {
    public let snapshot: Snapshot
    public let lockReason: LockReason?
  }

  /// The most recent state without adding an observation.
  public var currentSnapshot: Snapshot {
    snapshot(at: lastSampleAt ?? 0, idleSeconds: lastIdleSeconds)
  }

  /// Adds one RSSI observation. Invalid Core Bluetooth sentinel values are
  /// ignored instead of being treated as an extremely strong nearby signal.
  public mutating func ingest(
    rssi: Int,
    at timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Evaluation {
    lastIdleSeconds = max(0, idleSeconds)
    guard (-110 ... -1).contains(rssi) else {
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: lastIdleSeconds),
        lockReason: nil,
      )
    }

    lastSampleAt = timestamp
    signalLostSince = nil
    activitySuppressed = false

    let filtered = filter(rssi)
    lastFilteredRSSI = filtered
    recordTrend(filtered, at: timestamp)

    switch configuration.mode {
    case .smart:
      return evaluateSmart(filtered, at: timestamp, idleSeconds: lastIdleSeconds)
    case .manual:
      return evaluateManual(filtered, at: timestamp, idleSeconds: lastIdleSeconds)
    }
  }

  /// Evaluates a Bluetooth-on signal gap. Call after the normal 30-second
  /// freshness window and periodically afterward until a sample returns.
  public mutating func signalLost(
    at timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Evaluation {
    lastIdleSeconds = max(0, idleSeconds)
    signalLostSince = signalLostSince ?? lastSampleAt ?? timestamp

    guard armed, phase != .awayLatched else {
      phase = phase == .awayLatched ? .awayLatched : .signalLost
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: lastIdleSeconds),
        lockReason: nil,
      )
    }

    switch configuration.mode {
    case .manual:
      return latch(
        reason: .manualSignalLoss,
        at: timestamp,
        idleSeconds: lastIdleSeconds,
      )

    case .smart:
      let parameters = configuration.sensitivity.parameters
      let threshold = smartFarThreshold
      let isVeryWeak = lastFilteredRSSI.map { value in
        threshold.map { value < $0 - parameters.veryWeakGap } ?? false
      } ?? false
      let hadDepartureEvidence =
        phase == .suspectedAway
          || (lastFilteredRSSI.map { value in threshold.map { value < $0 + 2 } ?? false } ?? false)
          || (currentSlope.map { $0 <= parameters.departureSlope } ?? false)
      let recentlyActive = lastIdleSeconds < parameters.activeInputSeconds

      if hadDepartureEvidence, !recentlyActive || isVeryWeak {
        return latch(
          reason: .signalLostAfterWeakening,
          at: timestamp,
          idleSeconds: lastIdleSeconds,
        )
      }

      phase = .signalLost
      activitySuppressed = recentlyActive
      let lostFor = timestamp - (signalLostSince ?? timestamp)
      if lostFor >= Self.extendedSignalLossSeconds, lastIdleSeconds >= Self.extendedSignalLossIdleSeconds {
        return latch(
          reason: .extendedSignalLoss,
          at: timestamp,
          idleSeconds: lastIdleSeconds,
        )
      }

      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: lastIdleSeconds),
        lockReason: nil,
      )
    }
  }

  /// Advances a pending manual-mode grace period without requiring another
  /// RSSI callback. This preserves Manual mode's wall-clock delay when a weak
  /// reading is immediately followed by radio silence.
  public mutating func advanceTime(
    to timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Evaluation {
    lastIdleSeconds = max(0, idleSeconds)
    guard
      configuration.mode == .manual,
      armed,
      phase == .suspectedAway,
      let suspectedSince,
      timestamp - suspectedSince >= configuration.manualGraceSeconds
    else {
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: lastIdleSeconds),
        lockReason: nil,
      )
    }
    return latch(
      reason: .manualThreshold,
      at: timestamp,
      idleSeconds: lastIdleSeconds,
    )
  }

  /// Disarms after sleep, wake, a Bluetooth state transition, or a changed
  /// monitor. Smart mode keeps its learned nearby reference unless explicitly
  /// recalibrated, but still requires stable nearby evidence before re-arming.
  public mutating func reset(clearLearnedBaseline: Bool) {
    phase = .learning
    armed = configuration.mode == .manual
    rawWindow.removeAll()
    filteredHistory.removeAll()
    smartEWMA = nil
    initialSmartSamples.removeAll()
    suspectedSince = nil
    nearCandidateSince = nil
    signalLostSince = nil
    lastSampleAt = nil
    lastFilteredRSSI = nil
    lastIdleSeconds = 0
    activitySuppressed = false
    lastLockReason = nil
    if clearLearnedBaseline {
      learnedNearRSSI = nil
    }
  }

  // MARK: Private

  private struct TimedRSSI: Sendable {
    let at: TimeInterval
    let value: Double
  }

  private static let medianWindow = 5
  private static let trendWindowSeconds: TimeInterval = 8
  private static let smartEWMAAlpha = 0.4
  private static let extendedSignalLossSeconds: TimeInterval = 90
  private static let extendedSignalLossIdleSeconds: TimeInterval = 15
  private static let manualHysteresisGap = 6.0

  private let configuration: Configuration
  private var phase = Phase.learning
  private var armed: Bool
  private var rawWindow = [Int]()
  private var filteredHistory = [TimedRSSI]()
  private var smartEWMA: Double?
  private var initialSmartSamples = [Double]()
  private var learnedNearRSSI: Double?
  private var suspectedSince: TimeInterval?
  private var nearCandidateSince: TimeInterval?
  private var signalLostSince: TimeInterval?
  private var lastSampleAt: TimeInterval?
  private var lastFilteredRSSI: Double?
  private var lastIdleSeconds: TimeInterval = 0
  private var activitySuppressed = false
  private var lastLockReason: LockReason?

  private var currentSlope: Double? {
    guard
      let first = filteredHistory.first,
      let last = filteredHistory.last,
      filteredHistory.count >= 3,
      last.at - first.at >= 2
    else { return nil }
    return (last.value - first.value) / (last.at - first.at)
  }

  private var smartFarThreshold: Double? {
    learnedNearRSSI.map { $0 - configuration.sensitivity.parameters.farMargin }
  }

  private static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private mutating func filter(_ rssi: Int) -> Double {
    let windowSize = configuration.mode == .smart
      ? Self.medianWindow
      : configuration.manualSmoothing
    rawWindow.append(rssi)
    if rawWindow.count > windowSize {
      rawWindow.removeFirst(rawWindow.count - windowSize)
    }

    switch configuration.mode {
    case .manual:
      return Double(rawWindow.reduce(0, +)) / Double(rawWindow.count)

    case .smart:
      let median = Self.median(rawWindow.map(Double.init))
      let filtered = smartEWMA.map {
        (Self.smartEWMAAlpha * median) + ((1 - Self.smartEWMAAlpha) * $0)
      } ?? median
      smartEWMA = filtered
      return filtered
    }
  }

  private mutating func recordTrend(_ rssi: Double, at timestamp: TimeInterval) {
    filteredHistory.append(TimedRSSI(at: timestamp, value: rssi))
    let cutoff = timestamp - Self.trendWindowSeconds
    filteredHistory.removeAll { $0.at < cutoff }
  }

  private mutating func evaluateSmart(
    _ rssi: Double,
    at timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Evaluation {
    let parameters = configuration.sensitivity.parameters

    learnNearbyReference(rssi, idleSeconds: idleSeconds)
    guard let threshold = smartFarThreshold else {
      phase = .learning
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
        lockReason: nil,
      )
    }

    let returnThreshold = threshold + parameters.returnGap
    if phase == .awayLatched {
      if rssi >= returnThreshold {
        nearCandidateSince = nearCandidateSince ?? timestamp
        if timestamp - (nearCandidateSince ?? timestamp) >= parameters.rearmSeconds {
          phase = .near
          armed = true
          nearCandidateSince = nil
          lastLockReason = nil
        }
      } else {
        nearCandidateSince = nil
      }
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
        lockReason: nil,
      )
    }

    if !armed || phase == .learning {
      if rssi >= returnThreshold {
        nearCandidateSince = nearCandidateSince ?? timestamp
        if timestamp - (nearCandidateSince ?? timestamp) >= parameters.rearmSeconds {
          phase = .near
          armed = true
          nearCandidateSince = nil
        } else {
          phase = .learning
        }
      } else {
        nearCandidateSince = nil
        phase = .learning
      }
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
        lockReason: nil,
      )
    }

    if phase == .signalLost {
      phase = .near
    }

    let slope = currentSlope
    let weak = rssi < threshold
    let veryWeak = rssi < threshold - parameters.veryWeakGap
    let declining = slope.map { $0 <= parameters.departureSlope } ?? false
    let recentlyActive = idleSeconds < parameters.activeInputSeconds

    if phase == .suspectedAway {
      if rssi >= returnThreshold {
        phase = .near
        suspectedSince = nil
      } else if recentlyActive, !veryWeak {
        phase = .near
        suspectedSince = nil
        activitySuppressed = true
      } else {
        let confirmation = parameters.confirmationSeconds * (recentlyActive ? 1.5 : 1)
        if timestamp - (suspectedSince ?? timestamp) >= confirmation {
          return latch(
            reason: veryWeak ? .veryWeakSignal : .weakSignalTrend,
            at: timestamp,
            idleSeconds: idleSeconds,
          )
        }
      }
    } else if weak, declining || veryWeak {
      if recentlyActive, !veryWeak {
        activitySuppressed = true
      } else {
        phase = .suspectedAway
        suspectedSince = timestamp
      }
    } else {
      phase = .near
      suspectedSince = nil
    }

    return Evaluation(
      snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
      lockReason: nil,
    )
  }

  private mutating func learnNearbyReference(_ rssi: Double, idleSeconds: TimeInterval) {
    guard phase != .suspectedAway, phase != .awayLatched else { return }

    if learnedNearRSSI == nil {
      initialSmartSamples.append(rssi)
      if initialSmartSamples.count > Self.medianWindow {
        initialSmartSamples.removeFirst(initialSmartSamples.count - Self.medianWindow)
      }
      if initialSmartSamples.count == Self.medianWindow {
        learnedNearRSSI = Self.median(initialSmartSamples)
      }
      return
    }

    // Recent hardware input labels the current situation as "the user is at
    // this Mac." Follow stronger readings quickly, but let weaker readings
    // lower the baseline only very slowly so a departure can't teach itself as
    // the new normal.
    guard idleSeconds < configuration.sensitivity.parameters.learningInputSeconds else { return }
    let alpha = rssi >= (learnedNearRSSI ?? rssi) ? 0.25 : 0.02
    learnedNearRSSI = ((1 - alpha) * (learnedNearRSSI ?? rssi)) + (alpha * rssi)
  }

  private mutating func evaluateManual(
    _ rssi: Double,
    at timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Evaluation {
    let threshold = Double(configuration.manualFarRSSI)
    let returnThreshold = threshold + Self.manualHysteresisGap

    if phase == .awayLatched {
      if rssi >= threshold {
        armed = true
        phase = .near
        lastLockReason = nil
      }
      return Evaluation(
        snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
        lockReason: nil,
      )
    }

    if phase == .learning || phase == .signalLost {
      phase = .near
    }

    if rssi >= returnThreshold {
      phase = .near
      suspectedSince = nil
    } else if rssi < threshold, armed {
      if phase != .suspectedAway {
        phase = .suspectedAway
        suspectedSince = timestamp
      }
      if timestamp - (suspectedSince ?? timestamp) >= configuration.manualGraceSeconds {
        return latch(
          reason: .manualThreshold,
          at: timestamp,
          idleSeconds: idleSeconds,
        )
      }
    }

    return Evaluation(
      snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
      lockReason: nil,
    )
  }

  private mutating func latch(
    reason: LockReason,
    at timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Evaluation {
    phase = .awayLatched
    armed = false
    suspectedSince = nil
    nearCandidateSince = nil
    activitySuppressed = false
    lastLockReason = reason
    return Evaluation(
      snapshot: snapshot(at: timestamp, idleSeconds: idleSeconds),
      lockReason: reason,
    )
  }

  private func snapshot(
    at timestamp: TimeInterval,
    idleSeconds: TimeInterval,
  ) -> Snapshot {
    let threshold = configuration.mode == .smart
      ? smartFarThreshold
      : Double(configuration.manualFarRSSI)
    let secondsUntilLock: Int? =
      if
        phase == .suspectedAway,
        let suspectedSince
      {
        Int(
          ceil(
            max(
              0,
              confirmationSeconds(idleSeconds: idleSeconds) - (timestamp - suspectedSince),
            )
          )
        )
      } else {
        nil
      }

    return Snapshot(
      phase: phase,
      rssi: lastFilteredRSSI.map { Int($0.rounded()) },
      learnedNearRSSI: learnedNearRSSI.map { Int($0.rounded()) },
      farThresholdRSSI: threshold.map { Int($0.rounded()) },
      slope: currentSlope,
      idleSeconds: idleSeconds,
      isActivitySuppressed: activitySuppressed,
      secondsUntilLock: secondsUntilLock,
      lockReason: lastLockReason,
    )
  }

  private func confirmationSeconds(idleSeconds: TimeInterval) -> TimeInterval {
    switch configuration.mode {
    case .manual:
      return configuration.manualGraceSeconds
    case .smart:
      let parameters = configuration.sensitivity.parameters
      return parameters.confirmationSeconds * (idleSeconds < parameters.activeInputSeconds ? 1.5 : 1)
    }
  }

}

extension ProximitySensitivity {
  fileprivate struct Parameters {
    let farMargin: Double
    let confirmationSeconds: TimeInterval
    let rearmSeconds: TimeInterval
    let departureSlope: Double
    let returnGap: Double
    let veryWeakGap: Double
    let activeInputSeconds: TimeInterval
    let learningInputSeconds: TimeInterval
  }

  fileprivate var parameters: Parameters {
    switch self {
    case .conservative:
      Parameters(
        farMargin: 18,
        confirmationSeconds: 8,
        rearmSeconds: 5,
        departureSlope: -0.8,
        returnGap: 6,
        veryWeakGap: 10,
        activeInputSeconds: 4,
        learningInputSeconds: 8,
      )

    case .balanced:
      Parameters(
        farMargin: 14,
        confirmationSeconds: 5,
        rearmSeconds: 4,
        departureSlope: -0.6,
        returnGap: 6,
        veryWeakGap: 9,
        activeInputSeconds: 3,
        learningInputSeconds: 7,
      )

    case .fast:
      Parameters(
        farMargin: 11,
        confirmationSeconds: 3,
        rearmSeconds: 3,
        departureSlope: -0.4,
        returnGap: 5,
        veryWeakGap: 8,
        activeInputSeconds: 2,
        learningInputSeconds: 6,
      )
    }
  }
}
