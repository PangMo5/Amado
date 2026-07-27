import Foundation

// MARK: - ProximityDetectionMode

/// How Amado decides that the monitored iPhone left.
public enum ProximityDetectionMode: String, CaseIterable, Codable, Hashable, Sendable {
  /// Learns the nearby signal and combines robust RSSI filtering, its trend,
  /// weak-signal consistency, and signal-loss context.
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
    public let departureConfidence: Double
    public let secondsUntilLock: Int?
    public let lockReason: LockReason?
  }

  public struct Evaluation: Equatable, Sendable {
    public let snapshot: Snapshot
    public let lockReason: LockReason?
  }

  /// The most recent state without adding an observation.
  public var currentSnapshot: Snapshot {
    snapshot(at: lastSampleAt ?? 0)
  }

  /// Adds one RSSI observation. Invalid Core Bluetooth sentinel values are
  /// ignored instead of being treated as an extremely strong nearby signal.
  public mutating func ingest(
    rssi: Int,
    at timestamp: TimeInterval,
  ) -> Evaluation {
    guard (-110 ... -1).contains(rssi) else {
      return Evaluation(
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }

    lastSampleAt = timestamp
    signalLostSince = nil

    let filtered = filter(rssi)
    lastFilteredRSSI = filtered
    recordTrend(filtered, at: timestamp)

    switch configuration.mode {
    case .smart:
      return evaluateSmart(filtered, rawRSSI: Double(rssi), at: timestamp)
    case .manual:
      return evaluateManual(filtered, at: timestamp)
    }
  }

  /// Evaluates a Bluetooth-on signal gap. Call after the normal 30-second
  /// freshness window and periodically afterward until a sample returns.
  public mutating func signalLost(
    at timestamp: TimeInterval
  ) -> Evaluation {
    signalLostSince = signalLostSince ?? lastSampleAt ?? timestamp

    guard armed, phase != .awayLatched else {
      phase = phase == .awayLatched ? .awayLatched : .signalLost
      return Evaluation(
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }

    switch configuration.mode {
    case .manual:
      return latch(
        reason: .manualSignalLoss,
        at: timestamp,
      )

    case .smart:
      let parameters = configuration.sensitivity.parameters
      let threshold = smartFarThreshold
      let isVeryWeak = lastFilteredRSSI.map { value in
        threshold.map { value < $0 - parameters.veryWeakGap } ?? false
      } ?? false
      let stableSignalApproachedThreshold = lastFilteredRSSI.map { value in
        threshold.map { value < $0 + 2 } ?? false
      } ?? false
      let hadDepartureEvidence =
        phase == .suspectedAway
          || (
            stableSignalApproachedThreshold
              && (
                lastDepartureConfidence >= Self.meaningfulDepartureConfidence
                  || (currentSlope.map { $0 <= parameters.departureSlope } ?? false)
              )
          )

      if hadDepartureEvidence || isVeryWeak {
        return latch(
          reason: .signalLostAfterWeakening,
          at: timestamp,
        )
      }

      phase = .signalLost
      let lostFor = timestamp - (signalLostSince ?? timestamp)
      if lostFor >= Self.extendedSignalLossSeconds {
        return latch(
          reason: .extendedSignalLoss,
          at: timestamp,
        )
      }

      return Evaluation(
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }
  }

  /// Advances a pending manual-mode grace period without requiring another
  /// RSSI callback. This preserves Manual mode's wall-clock delay when a weak
  /// reading is immediately followed by radio silence.
  public mutating func advanceTime(
    to timestamp: TimeInterval
  ) -> Evaluation {
    guard
      configuration.mode == .manual,
      armed,
      phase == .suspectedAway,
      let suspectedSince,
      timestamp - suspectedSince >= configuration.manualGraceSeconds
    else {
      return Evaluation(
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }
    return latch(
      reason: .manualThreshold,
      at: timestamp,
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
    nearbyReferenceSamples.removeAll()
    suspectedSince = nil
    nearCandidateSince = nil
    signalLostSince = nil
    lastSampleAt = nil
    lastFilteredRSSI = nil
    lastDepartureConfidence = 0
    pendingConfirmationSeconds = nil
    lastLockReason = nil
    if clearLearnedBaseline {
      calibratedNearRSSI = nil
      learnedNearRSSI = nil
    }
  }

  // MARK: Private

  private struct TimedRSSI: Sendable {
    let at: TimeInterval
    let value: Double
  }

  private struct DepartureEvidence {
    let confidence: Double
    let isNear: Bool
    let isDepartureCandidate: Bool
    let isDecisive: Bool
  }

  private static let medianWindow = 5
  private static let trendWindowSeconds: TimeInterval = 8
  private static let smartEWMAAlpha = 0.4
  private static let extendedSignalLossSeconds: TimeInterval = 90
  private static let manualHysteresisGap = 6.0
  private static let fastMedianWindow = 3
  private static let highDepartureConfidence = 0.85
  private static let meaningfulDepartureConfidence = 0.5
  private static let minimumAdaptiveConfirmationSeconds: TimeInterval = 0.75
  private static let nearbyReferenceWindow = 21
  private static let maximumNearbyReferenceDrift = 4.0
  /// A momentarily excellent RSSI must not tighten the departure threshold.
  /// `-45 dBm` is already unambiguously nearby across supported presets.
  private static let strongestTrustedNearRSSI = -45.0

  private let configuration: Configuration
  private var phase = Phase.learning
  private var armed: Bool
  private var rawWindow = [Int]()
  private var filteredHistory = [TimedRSSI]()
  private var smartEWMA: Double?
  private var initialSmartSamples = [Double]()
  private var nearbyReferenceSamples = [Double]()
  private var calibratedNearRSSI: Double?
  private var learnedNearRSSI: Double?
  private var suspectedSince: TimeInterval?
  private var nearCandidateSince: TimeInterval?
  private var signalLostSince: TimeInterval?
  private var lastSampleAt: TimeInterval?
  private var lastFilteredRSSI: Double?
  private var lastDepartureConfidence = 0.0
  private var pendingConfirmationSeconds: TimeInterval?
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
    learnedNearRSSI.map {
      min($0, Self.strongestTrustedNearRSSI)
        - configuration.sensitivity.parameters.farMargin
    }
  }

  private var confirmationSeconds: TimeInterval {
    switch configuration.mode {
    case .manual:
      configuration.manualGraceSeconds
    case .smart:
      pendingConfirmationSeconds ?? configuration.sensitivity.parameters.confirmationSeconds
    }
  }

  private static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
  }

  private static func adaptiveConfirmationSeconds(
    base: TimeInterval,
    confidence: Double,
  ) -> TimeInterval {
    max(
      minimumAdaptiveConfirmationSeconds,
      base * (1 - (0.75 * clamp(confidence))),
    )
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

  private func departureEvidence(
    filteredRSSI: Double,
    rawRSSI: Double,
    threshold: Double,
    parameters: ProximitySensitivity.Parameters,
  ) -> DepartureEvidence {
    let fastSamples = rawWindow.suffix(Self.fastMedianWindow).map(Double.init)
    let fastRSSI = Self.median(fastSamples)
    let returnThreshold = threshold + parameters.returnGap
    let evidenceRange = parameters.returnGap + parameters.veryWeakGap
    let fastLevel = Self.clamp((returnThreshold - fastRSSI) / evidenceRange)
    let filteredLevel = Self.clamp((returnThreshold - filteredRSSI) / evidenceRange)
    let weakConsistency =
      Double(rawWindow.count { Double($0) < threshold })
        / Double(max(1, rawWindow.count))
    let slope = currentSlope ?? 0
    let trend = Self.clamp(
      max(0, -slope) / max(0.1, abs(parameters.departureSlope) * 3)
    )
    let confidence = Self.clamp(
      (0.4 * fastLevel)
        + (0.25 * filteredLevel)
        + (0.2 * trend)
        + (0.15 * weakConsistency)
    )
    // Fast samples contribute to confidence, but ordinary departure timing
    // starts only after the stable filter also crosses the threshold. This
    // prevents a normal near-field fade from becoming a false departure.
    let isDepartureCandidate = filteredRSSI < threshold
    let isDecisive =
      rawRSSI < threshold - parameters.veryWeakGap
        && fastRSSI < threshold - parameters.veryWeakGap
        && weakConsistency >= 0.6

    return DepartureEvidence(
      confidence: confidence,
      isNear: fastRSSI >= returnThreshold && filteredRSSI >= returnThreshold,
      isDepartureCandidate: isDepartureCandidate,
      isDecisive: isDecisive,
    )
  }

  private mutating func evaluateSmart(
    _ rssi: Double,
    rawRSSI: Double,
    at timestamp: TimeInterval,
  ) -> Evaluation {
    let parameters = configuration.sensitivity.parameters

    learnInitialNearbyReference(rssi)
    guard let threshold = smartFarThreshold else {
      phase = .learning
      return Evaluation(
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }

    let returnThreshold = threshold + parameters.returnGap
    if phase == .awayLatched {
      if rssi >= returnThreshold {
        refineNearbyReference(rssi)
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
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }

    if !armed || phase == .learning {
      if rssi >= returnThreshold {
        refineNearbyReference(rssi)
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
        snapshot: snapshot(at: timestamp),
        lockReason: nil,
      )
    }

    if phase == .signalLost {
      phase = .near
    }

    let evidence = departureEvidence(
      filteredRSSI: rssi,
      rawRSSI: rawRSSI,
      threshold: threshold,
      parameters: parameters,
    )
    lastDepartureConfidence = evidence.confidence

    if evidence.isNear {
      refineNearbyReference(rssi)
      phase = .near
      suspectedSince = nil
      pendingConfirmationSeconds = nil
      lastDepartureConfidence = 0
    } else if evidence.isDepartureCandidate {
      if phase != .suspectedAway {
        phase = .suspectedAway
        suspectedSince = timestamp
      }
      let confirmation = Self.adaptiveConfirmationSeconds(
        base: parameters.confirmationSeconds,
        confidence: evidence.confidence,
      )
      pendingConfirmationSeconds = confirmation
      if
        evidence.confidence >= Self.highDepartureConfidence
        || timestamp - (suspectedSince ?? timestamp) >= confirmation
      {
        return latch(
          reason: evidence.isDecisive ? .veryWeakSignal : .weakSignalTrend,
          at: timestamp,
        )
      }
    } else {
      phase = .near
      suspectedSince = nil
      pendingConfirmationSeconds = nil
    }

    return Evaluation(
      snapshot: snapshot(at: timestamp),
      lockReason: nil,
    )
  }

  private mutating func learnInitialNearbyReference(_ rssi: Double) {
    guard learnedNearRSSI == nil else { return }

    initialSmartSamples.append(rssi)
    if initialSmartSamples.count > Self.medianWindow {
      initialSmartSamples.removeFirst(initialSmartSamples.count - Self.medianWindow)
    }
    guard initialSmartSamples.count == Self.medianWindow else { return }

    let calibratedReference = min(
      Self.median(initialSmartSamples),
      Self.strongestTrustedNearRSSI,
    )
    calibratedNearRSSI = calibratedReference
    learnedNearRSSI = calibratedReference
    nearbyReferenceSamples = initialSmartSamples
  }

  /// Refines the nearby reference only from independently confirmed Bluetooth
  /// proximity. Strong peaks may remain in the rolling window, but they cannot
  /// tighten a previously safe threshold; weaker stable-near observations can
  /// make it more conservative. Recalibration is the explicit way to request a
  /// tighter reference after the phone's normal placement changes.
  private mutating func refineNearbyReference(_ rssi: Double) {
    guard
      let calibratedNearRSSI,
      let learnedNearRSSI
    else { return }

    nearbyReferenceSamples.append(rssi)
    if nearbyReferenceSamples.count > Self.nearbyReferenceWindow {
      nearbyReferenceSamples.removeFirst(
        nearbyReferenceSamples.count - Self.nearbyReferenceWindow
      )
    }
    let robustReference = min(
      Self.median(nearbyReferenceSamples),
      Self.strongestTrustedNearRSSI,
    )
    let weakestAllowedReference =
      calibratedNearRSSI - Self.maximumNearbyReferenceDrift
    self.learnedNearRSSI = min(
      learnedNearRSSI,
      max(robustReference, weakestAllowedReference),
    )
  }

  private mutating func evaluateManual(
    _ rssi: Double,
    at timestamp: TimeInterval,
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
        snapshot: snapshot(at: timestamp),
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
        )
      }
    }

    return Evaluation(
      snapshot: snapshot(at: timestamp),
      lockReason: nil,
    )
  }

  private mutating func latch(
    reason: LockReason,
    at timestamp: TimeInterval,
  ) -> Evaluation {
    phase = .awayLatched
    armed = false
    suspectedSince = nil
    nearCandidateSince = nil
    pendingConfirmationSeconds = nil
    lastLockReason = reason
    return Evaluation(
      snapshot: snapshot(at: timestamp),
      lockReason: reason,
    )
  }

  private func snapshot(
    at timestamp: TimeInterval
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
              confirmationSeconds - (timestamp - suspectedSince),
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
      departureConfidence: lastDepartureConfidence,
      secondsUntilLock: secondsUntilLock,
      lockReason: lastLockReason,
    )
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
      )

    case .balanced:
      Parameters(
        farMargin: 14,
        confirmationSeconds: 5,
        rearmSeconds: 4,
        departureSlope: -0.6,
        returnGap: 6,
        veryWeakGap: 9,
      )

    case .fast:
      Parameters(
        farMargin: 11,
        confirmationSeconds: 3,
        rearmSeconds: 3,
        departureSlope: -0.4,
        returnGap: 5,
        veryWeakGap: 8,
      )
    }
  }
}
