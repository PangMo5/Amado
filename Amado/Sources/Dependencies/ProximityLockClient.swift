import AmadoKit
import AppKit
import CoreBluetooth
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - DiscoveredDevice

/// One nearby BLE device for the Settings picker. `id` is the CoreBluetooth local
/// identifier — stable per-Mac when the phone is resolvable via the same-iCloud
/// IRK, so it survives the iPhone's ~15-min address rotation.
struct DiscoveredDevice: Equatable, Sendable, Identifiable {
  let id: UUID
  let name: String
  let rssi: Int
}

// MARK: - ProximityStatus

/// Live status of the monitored device, for the Settings status line.
enum ProximityStatus: Equatable, Sendable {
  case disabled
  case waitingForBluetooth
  case searching
  case learning(rssi: Int?)
  case near(rssi: Int, threshold: Int)
  case leaving(rssi: Int, threshold: Int, secondsRemaining: Int?)
  case reacquiring
  case away(reason: ProximityDecisionEngine.LockReason)
  case signalLost
}

// MARK: - ProximityMonitorConfiguration

struct ProximityMonitorConfiguration: Equatable, Sendable {
  let deviceID: UUID?
  let mode: ProximityDetectionMode
  let sensitivity: ProximitySensitivity
  let manualFarRSSI: Int
  let manualGraceSeconds: TimeInterval
  let manualSmoothing: Int

  var decisionConfiguration: ProximityDecisionEngine.Configuration {
    ProximityDecisionEngine.Configuration(
      mode: mode,
      sensitivity: sensitivity,
      manualFarRSSI: manualFarRSSI,
      manualGraceSeconds: manualGraceSeconds,
      manualSmoothing: manualSmoothing,
    )
  }
}

// MARK: - ProximityLockClient

/// The Mac scans for a chosen nearby device — typically the owner's iPhone, seen
/// via its native Continuity BLE advertising, with **no app on the phone** — and
/// locks this Mac when that device's RSSI trend says it left. Recognizing the
/// iPhone across its rotating private address works because a Mac + iPhone on the
/// same iCloud account share the device's IRK (via iCloud Keychain), so macOS
/// resolves the address to a stable `CBPeripheral.identifier`. Lock-only: no
/// unlock, no stored password.
@DependencyClient
struct ProximityLockClient: Sendable {
  /// Start or refresh monitoring. A nil `deviceID` stops it.
  var monitor: @Sendable (_ configuration: ProximityMonitorConfiguration) -> Void
  /// Clear smart mode's learned nearby baseline and require stable nearby
  /// observations before re-arming.
  var recalibrate: @Sendable () -> Void
  /// Enter scan mode so `discovered()` lists nearby named devices for the picker.
  var startScanning: @Sendable () -> Void
  /// Leave scan mode (monitoring, if any, continues).
  var stopScanning: @Sendable () -> Void
  /// Nearby named devices, newest snapshot, sorted by RSSI desc.
  var discovered: @Sendable () -> AsyncStream<[DiscoveredDevice]> = { AsyncStream { _ in } }
  /// One reason each time the monitored device is confirmed gone.
  var farEvents: @Sendable () -> AsyncStream<ProximityDecisionEngine.LockReason> = { AsyncStream { _ in } }
  /// Live status of the monitored device, for the Settings status line.
  var status: @Sendable () -> AsyncStream<ProximityStatus> = { AsyncStream { _ in } }
}

// MARK: DependencyKey

extension ProximityLockClient: DependencyKey {
  static let liveValue: ProximityLockClient = {
    let engine = ProximityEngine()
    return ProximityLockClient(
      monitor: { engine.setMonitor($0) },
      recalibrate: { engine.recalibrate() },
      startScanning: { engine.setScanMode(true) },
      stopScanning: { engine.setScanMode(false) },
      discovered: { engine.discoveredStream },
      farEvents: { engine.farStream },
      status: { engine.statusStream },
    )
  }()

  static let testValue = ProximityLockClient(
    monitor: { _ in },
    recalibrate: { },
    startScanning: { },
    stopScanning: { },
    discovered: { AsyncStream { _ in } },
    farEvents: { AsyncStream { _ in } },
    status: { AsyncStream { _ in } },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var proximityLock: ProximityLockClient {
    get { self[ProximityLockClient.self] }
    set { self[ProximityLockClient.self] = newValue }
  }
}

// MARK: - ProximityEngine

/// `@unchecked Sendable`: every field is touched only on `queue`. CoreBluetooth
/// delivers its delegate callbacks on `queue` (passed to `CBCentralManager`), and
/// the public setters hop onto it, so no lock is needed.
private final class ProximityEngine: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

  // MARK: Lifecycle

  override init() {
    (discoveredStream, discoveredCont) = Self.makeStream()
    (farStream, farCont) = Self.makeStream()
    (statusStream, statusCont) = Self.makeStream()
    super.init()
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    workspaceCenter.addObserver(
      self,
      selector: #selector(workspaceWillSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil,
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(workspaceDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil,
    )
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  // MARK: Internal

  let discoveredStream: AsyncStream<[DiscoveredDevice]>
  let farStream: AsyncStream<ProximityDecisionEngine.LockReason>
  let statusStream: AsyncStream<ProximityStatus>

  func setMonitor(_ configuration: ProximityMonitorConfiguration) {
    queue.async {
      self.monitoredID = configuration.deviceID
      self.monitorMode = configuration.mode
      self.decisionEngine = ProximityDecisionEngine(configuration: configuration.decisionConfiguration)
      self.resetConnectionState(clearLearnedBaseline: false)
      self.ensureManager()
      self.reacquireMonitored()
      self.applyScan()
      self.emitStatus(configuration.deviceID == nil ? .disabled : .searching)
    }
  }

  func recalibrate() {
    queue.async {
      guard self.monitoredID != nil else { return }
      self.decisionEngine.reset(clearLearnedBaseline: true)
      self.emitStatus(.learning(rssi: nil))
      self.loggerSnapshot(self.decisionEngine.currentSnapshot, event: "recalibrated")
    }
  }

  func setScanMode(_ on: Bool) {
    queue.async {
      self.scanMode = on
      if on { self.seen.removeAll() } // fresh list every time the picker opens
      self.ensureManager()
      self.applyScan()
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      suspended = false
      decisionEngine.reset(clearLearnedBaseline: false)
      reacquireMonitored()
      applyScan()
      emitStatus(monitoredID == nil ? .disabled : .reacquiring)
    } else {
      resetConnectionState(clearLearnedBaseline: false)
      emitStatus(.waitingForBluetooth)
    }
  }

  func centralManager(
    _: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber,
  ) {
    let rssi = RSSI.intValue

    if scanMode, (-110 ... -1).contains(rssi) {
      let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
      if let name, !name.isEmpty {
        seen[peripheral.identifier] = (DiscoveredDevice(id: peripheral.identifier, name: name, rssi: rssi), Date())
        scheduleDiscoveredFlush()
      }
    }

    guard peripheral.identifier == monitoredID else { return }
    if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
    if !active, (-110 ... -1).contains(rssi) {
      ingest(rssi)
      connectMonitored()
    }
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral.identifier == monitoredID else { return }
    peripheral.delegate = self
    active = true
    lastReadAt = Date()
    peripheral.readRSSI()
    schedulePoll(peripheral) // self-rearming; survives read errors/stalls
  }

  func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error _: Error?) {
    active = false // stay on the passive scan-RSSI path
  }

  func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error _: Error?) {
    active = false
    if monitoredID != nil { connectMonitored() } // reconnect when back in range
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    // Only record successful reads. The poll loop is driven by `schedulePoll`,
    // NOT rescheduled here — so an errored read can't kill it, and a stalled
    // read lets `lastReadAt` go stale so the stall branch trips.
    guard peripheral.identifier == monitoredID, error == nil else { return }
    lastReadAt = Date()
    ingest(RSSI.intValue)
  }

  // MARK: Private

  private static let signalTimeout: TimeInterval = 30
  private static let signalRecheckSeconds: TimeInterval = 15
  private static let rssiPollSeconds: TimeInterval = 1
  private static let activeStallSeconds: TimeInterval = 10
  private static let discoveredTTL: TimeInterval = 5 // drop picker entries not seen recently

  private let queue = DispatchQueue(label: "dev.PangMo5.Amado.proximityLock")
  private var central: CBCentralManager?
  private var monitoredID: UUID?
  private var monitoredPeripheral: CBPeripheral?
  private var monitorMode = ProximityDetectionMode.smart
  private var decisionEngine = ProximityDecisionEngine(configuration: .init())
  private var active = false
  private var suspended = false
  private var signalTimer: DispatchWorkItem?
  private var manualDecisionTimer: DispatchWorkItem?
  private var pollTimer: DispatchWorkItem?
  private var scanMode = false
  private var seen = [UUID: (device: DiscoveredDevice, at: Date)]()
  private var discoveredFlush: DispatchWorkItem?
  private var lastReadAt = Date.distantPast
  private var lastStatus: ProximityStatus?
  private var lastLoggedPhase: ProximityDecisionEngine.Phase?
  private let discoveredCont: AsyncStream<[DiscoveredDevice]>.Continuation
  private let farCont: AsyncStream<ProximityDecisionEngine.LockReason>.Continuation
  private let statusCont: AsyncStream<ProximityStatus>.Continuation

  private static func makeStream<T>() -> (AsyncStream<T>, AsyncStream<T>.Continuation) {
    var continuation: AsyncStream<T>.Continuation!
    let stream = AsyncStream<T>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    return (stream, continuation)
  }

  private func ingest(_ rssi: Int) {
    guard (-110 ... -1).contains(rssi), !suspended else { return }
    let evaluation = decisionEngine.ingest(
      rssi: rssi,
      at: ProcessInfo.processInfo.systemUptime,
    )
    apply(evaluation)
    scheduleSignalCheck(after: Self.signalTimeout)
  }

  private func scheduleSignalCheck(after delay: TimeInterval) {
    signalTimer?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard
        let self,
        monitoredID != nil,
        !suspended,
        central?.state == .poweredOn
      else { return }
      let evaluation = decisionEngine.signalLost(
        at: ProcessInfo.processInfo.systemUptime
      )
      apply(evaluation)
      if evaluation.lockReason == nil {
        scheduleSignalCheck(after: Self.signalRecheckSeconds)
      }
    }
    signalTimer = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func apply(_ evaluation: ProximityDecisionEngine.Evaluation) {
    let snapshot = evaluation.snapshot
    emitStatus(status(for: snapshot))
    scheduleManualDecisionCheck(for: snapshot)
    if
      snapshot.phase != lastLoggedPhase
      || evaluation.lockReason != nil
    {
      loggerSnapshot(snapshot, event: evaluation.lockReason?.rawValue ?? "state")
      lastLoggedPhase = snapshot.phase
    }
    if let reason = evaluation.lockReason {
      fireLock(reason: reason)
    }
  }

  private func scheduleManualDecisionCheck(for snapshot: ProximityDecisionEngine.Snapshot) {
    manualDecisionTimer?.cancel()
    manualDecisionTimer = nil
    guard
      monitorMode == .manual,
      snapshot.phase == .suspectedAway,
      let secondsUntilLock = snapshot.secondsUntilLock
    else { return }

    let work = DispatchWorkItem { [weak self] in
      guard let self, monitoredID != nil, !suspended else { return }
      let evaluation = decisionEngine.advanceTime(
        to: ProcessInfo.processInfo.systemUptime
      )
      apply(evaluation)
    }
    manualDecisionTimer = work
    queue.asyncAfter(
      deadline: .now() + max(0.05, TimeInterval(secondsUntilLock)),
      execute: work,
    )
  }

  private func status(for snapshot: ProximityDecisionEngine.Snapshot) -> ProximityStatus {
    switch snapshot.phase {
    case .learning:
      .learning(rssi: snapshot.rssi)

    case .near:
      if let rssi = snapshot.rssi, let threshold = snapshot.farThresholdRSSI {
        .near(rssi: rssi, threshold: threshold)
      } else {
        .searching
      }

    case .suspectedAway:
      if let rssi = snapshot.rssi, let threshold = snapshot.farThresholdRSSI {
        .leaving(
          rssi: rssi,
          threshold: threshold,
          secondsRemaining: snapshot.secondsUntilLock,
        )
      } else {
        .searching
      }

    case .signalLost:
      .signalLost

    case .awayLatched:
      .away(reason: snapshot.lockReason ?? .extendedSignalLoss)
    }
  }

  private func loggerSnapshot(
    _ snapshot: ProximityDecisionEngine.Snapshot,
    event: String,
  ) {
    logger.log(
      """
      proximity: event=\(event, privacy: .public) phase=\(snapshot.phase.rawValue, privacy: .public) \
      rssi=\(snapshot.rssi ?? 0) baseline=\(snapshot.learnedNearRSSI ?? 0) \
      threshold=\(snapshot.farThresholdRSSI ?? 0) slope=\(snapshot.slope ?? 0, format: .fixed(precision: 2)) \
      confidence=\(snapshot.departureConfidence, format: .fixed(precision: 2))
      """
    )
  }

  /// Lock only if the session isn't already locked — avoids redundant work at
  /// the login window while preserving the away latch.
  private func fireLock(reason: ProximityDecisionEngine.LockReason) {
    guard !MacSessionState.isLocked() else { return }
    farCont.yield(reason)
  }

  private func ensureManager() {
    if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
  }

  private func reacquireMonitored() {
    guard let central, central.state == .poweredOn, let id = monitoredID else { return }
    if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
      monitoredPeripheral = peripheral
      connectMonitored()
    }
  }

  private func connectMonitored() {
    guard
      let central,
      central.state == .poweredOn,
      !suspended,
      let peripheral = monitoredPeripheral,
      peripheral.state == .disconnected
    else { return }
    central.connect(peripheral, options: nil) // RSSI-only, reads no chars → no pairing prompt
  }

  /// Self-rearming active-RSSI poll: ticks every `rssiPollSeconds` regardless of
  /// whether a read ever calls back, so a stalled or error-returning connection
  /// is torn down after `activeStallSeconds` (→ didDisconnect → reconnect / the
  /// passive scan path) instead of freezing and letting the 30s signal cap lock a
  /// phone that never left. Tracked in `pollTimer` so a lifecycle reset cancels
  /// it (no overlapping poll chains after a re-monitor).
  private func schedulePoll(_ peripheral: CBPeripheral) {
    pollTimer?.cancel()
    let work = DispatchWorkItem { [weak self, weak peripheral] in
      guard let self, let peripheral, active, peripheral.identifier == monitoredID else { return }
      if Date().timeIntervalSince(lastReadAt) > Self.activeStallSeconds {
        central?.cancelPeripheralConnection(peripheral)
        active = false // fall back to the passive scan-RSSI path
      } else {
        if peripheral.state == .connected { peripheral.readRSSI() }
        schedulePoll(peripheral)
      }
    }
    pollTimer = work
    queue.asyncAfter(deadline: .now() + Self.rssiPollSeconds, execute: work)
  }

  private func applyScan() {
    guard let central, central.state == .poweredOn, !suspended else { return }
    let wants = scanMode || monitoredID != nil
    if wants {
      guard !central.isScanning else { return }
      central.scanForPeripherals(
        withServices: nil,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true],
      )
    } else if central.isScanning {
      central.stopScan()
    }
  }

  private func resetConnectionState(clearLearnedBaseline: Bool) {
    active = false
    decisionEngine.reset(clearLearnedBaseline: clearLearnedBaseline)
    signalTimer?.cancel()
    signalTimer = nil
    manualDecisionTimer?.cancel()
    manualDecisionTimer = nil
    pollTimer?.cancel()
    pollTimer = nil
    if let central, let peripheral = monitoredPeripheral { central.cancelPeripheralConnection(peripheral) }
    monitoredPeripheral = nil
    lastLoggedPhase = nil
  }

  @objc
  private func workspaceWillSleep(_: Notification) {
    queue.async {
      self.suspended = true
      self.central?.stopScan()
      self.resetConnectionState(clearLearnedBaseline: false)
      self.emitStatus(self.monitoredID == nil ? .disabled : .reacquiring)
    }
  }

  @objc
  private func workspaceDidWake(_: Notification) {
    queue.async {
      self.suspended = false
      self.resetConnectionState(clearLearnedBaseline: false)
      self.reacquireMonitored()
      self.applyScan()
      self.emitStatus(self.monitoredID == nil ? .disabled : .reacquiring)
    }
  }

  private func scheduleDiscoveredFlush() {
    guard discoveredFlush == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      discoveredFlush = nil
      let cutoff = Date().addingTimeInterval(-Self.discoveredTTL)
      seen = seen.filter { $0.value.at >= cutoff } // drop devices gone from range
      discoveredCont.yield(seen.values.map(\.device).sorted { $0.rssi > $1.rssi })
    }
    discoveredFlush = work
    queue.asyncAfter(deadline: .now() + 0.5, execute: work) // debounce the allowDuplicates flood
  }

  private func emitStatus(_ status: ProximityStatus) {
    guard status != lastStatus else { return }
    lastStatus = status
    statusCont.yield(status)
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "ProximityLock")
