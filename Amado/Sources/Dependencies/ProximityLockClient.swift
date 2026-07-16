import CoreBluetooth
import CoreGraphics
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
  case near(rssi: Int)
  case leaving(rssi: Int)
  case away
  case signalLost
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
  /// Start/refresh monitoring the selected device. Resets the state machine
  /// (presence assumed near, so no spurious lock at start). `deviceID == nil`
  /// stops monitoring. `farRSSI` = dBm at/below which — smoothed, sustained for
  /// `grace` — the Mac counts as "left". Idempotent.
  var monitor: @Sendable (_ deviceID: UUID?, _ farRSSI: Int, _ grace: TimeInterval, _ smoothing: Int) -> Void
  /// Enter scan mode so `discovered()` lists nearby named devices for the picker.
  var startScanning: @Sendable () -> Void
  /// Leave scan mode (monitoring, if any, continues).
  var stopScanning: @Sendable () -> Void
  /// Nearby named devices, newest snapshot, sorted by RSSI desc.
  var discovered: @Sendable () -> AsyncStream<[DiscoveredDevice]> = { AsyncStream { _ in } }
  /// One `()` each time the monitored device is confirmed gone → reducer locks.
  var farEvents: @Sendable () -> AsyncStream<Void> = { AsyncStream { _ in } }
  /// Live status of the monitored device, for the Settings status line.
  var status: @Sendable () -> AsyncStream<ProximityStatus> = { AsyncStream { _ in } }
}

// MARK: DependencyKey

extension ProximityLockClient: DependencyKey {
  static let liveValue: ProximityLockClient = {
    let engine = ProximityEngine()
    return ProximityLockClient(
      monitor: { id, far, grace, smoothing in
        engine.setMonitor(deviceID: id, farRSSI: far, grace: grace, smoothing: smoothing)
      },
      startScanning: { engine.setScanMode(true) },
      stopScanning: { engine.setScanMode(false) },
      discovered: { engine.discoveredStream },
      farEvents: { engine.farStream },
      status: { engine.statusStream },
    )
  }()

  static let testValue = ProximityLockClient(
    monitor: { _, _, _, _ in },
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
  }

  // MARK: Internal

  let discoveredStream: AsyncStream<[DiscoveredDevice]>
  let farStream: AsyncStream<Void>
  let statusStream: AsyncStream<ProximityStatus>

  func setMonitor(deviceID: UUID?, farRSSI: Int, grace: TimeInterval, smoothing: Int) {
    queue.async {
      self.monitoredID = deviceID
      self.farRSSI = farRSSI
      self.grace = grace
      self.smoothingWindow = max(1, smoothing)
      self.resetStateMachine()
      self.ensureManager()
      self.reacquireMonitored()
      self.applyScan()
      self.emitStatus(deviceID == nil ? .disabled : .searching)
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
      reacquireMonitored()
      applyScan()
      // Clear a stale .waitingForBluetooth once the radio is back; a reading
      // will move it to .near/.leaving shortly if the device is around.
      emitStatus(monitoredID == nil ? .disabled : .searching)
    } else {
      emitStatus(.waitingForBluetooth)
    }
  }

  func centralManager(
    _: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber,
  ) {
    let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue // clamp bogus positives

    if scanMode {
      let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
      if let name, !name.isEmpty {
        seen[peripheral.identifier] = (DiscoveredDevice(id: peripheral.identifier, name: name, rssi: rssi), Date())
        scheduleDiscoveredFlush()
      }
    }

    guard peripheral.identifier == monitoredID else { return }
    if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
    if !active {
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
    ingest(RSSI.intValue > 0 ? 0 : RSSI.intValue)
  }

  // MARK: Private

  private static let hysteresisGap = 6 // dBm; cancel a departure only on a clear return (anti-oscillation)
  private static let signalTimeout: TimeInterval = 30 // full loss → lock (security cap)
  private static let rssiPollSeconds: TimeInterval = 1
  private static let activeStallSeconds: TimeInterval = 10
  private static let discoveredTTL: TimeInterval = 5 // drop picker entries not seen recently

  private let queue = DispatchQueue(label: "dev.PangMo5.Amado.proximityLock")
  private var central: CBCentralManager?
  private var monitoredID: UUID?
  private var monitoredPeripheral: CBPeripheral?
  private var farRSSI = -56
  private var grace: TimeInterval = 2
  private var smoothingWindow = 3
  private var presence = true
  private var active = false
  private var buffer = [Int]()
  private var farTimer: DispatchWorkItem?
  private var signalTimer: DispatchWorkItem?
  private var pollTimer: DispatchWorkItem?
  private var scanMode = false
  private var seen = [UUID: (device: DiscoveredDevice, at: Date)]()
  private var discoveredFlush: DispatchWorkItem?
  private var lastReadAt = Date.distantPast
  private var lastStatus: ProximityStatus?

  private let discoveredCont: AsyncStream<[DiscoveredDevice]>.Continuation
  private let farCont: AsyncStream<Void>.Continuation
  private let statusCont: AsyncStream<ProximityStatus>.Continuation

  private static func isSessionLocked() -> Bool {
    guard
      let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
      let locked = dict["CGSSessionScreenIsLocked"] as? Int
    else { return false }
    return locked == 1
  }

  private static func makeStream<T>() -> (AsyncStream<T>, AsyncStream<T>.Continuation) {
    var continuation: AsyncStream<T>.Continuation!
    let stream = AsyncStream<T>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    return (stream, continuation)
  }

  private func ingest(_ rssi: Int) {
    resetSignalTimer()
    let avg = smooth(rssi)
    let nearRSSI = farRSSI + Self.hysteresisGap

    // Re-arm lockability as soon as we're back above the leave line, so a return
    // never leaves us permanently unable to lock (closes the earlier dead-band).
    if avg >= farRSSI { presence = true }

    if avg >= nearRSSI {
      // Clearly back → cancel any pending departure.
      cancelFarTimer()
      emitStatus(.near(rssi: avg))
    } else if avg < farRSSI, presence, farTimer == nil {
      // Past the leave line → start the grace countdown.
      emitStatus(.leaving(rssi: avg))
      scheduleFar()
    }
    // In the [farRSSI, nearRSSI) band we neither cancel nor start: a running
    // countdown keeps running, so boundary oscillation can't perpetually reset
    // it (the bug where "Signal weak" showed but the Mac never locked).
  }

  private func scheduleFar() {
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      farTimer = nil
      presence = false // latch → no repeat locks until re-armed
      emitStatus(.away)
      fireLock()
    }
    farTimer = work
    queue.asyncAfter(deadline: .now() + grace, execute: work)
  }

  private func cancelFarTimer() {
    farTimer?.cancel()
    farTimer = nil
  }

  private func resetSignalTimer() {
    signalTimer?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      emitStatus(.signalLost)
      if presence { // full signal loss = security cap → lock
        presence = false
        fireLock()
      }
    }
    signalTimer = work
    queue.asyncAfter(deadline: .now() + Self.signalTimeout, execute: work)
  }

  private func smooth(_ rssi: Int) -> Int {
    buffer.append(rssi)
    if buffer.count > smoothingWindow { buffer.removeFirst(buffer.count - smoothingWindow) }
    return buffer.reduce(0, +) / buffer.count
  }

  /// Lock only if the session isn't already locked — avoids redundant work at the
  /// login window.
  private func fireLock() {
    guard !Self.isSessionLocked() else { return }
    logger.log("proximity: device left → locking")
    farCont.yield(())
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
    guard let central, let peripheral = monitoredPeripheral, peripheral.state == .disconnected else { return }
    central.connect(peripheral, options: nil) // RSSI-only, reads no chars → no pairing prompt
  }

  /// Self-rearming active-RSSI poll: ticks every `rssiPollSeconds` regardless of
  /// whether a read ever calls back, so a stalled or error-returning connection
  /// is torn down after `activeStallSeconds` (→ didDisconnect → reconnect / the
  /// passive scan path) instead of freezing and letting the 30s signal cap lock a
  /// phone that never left. Tracked in `pollTimer` so `resetStateMachine` cancels
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
    guard let central, central.state == .poweredOn else { return }
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

  private func resetStateMachine() {
    presence = true
    active = false
    buffer.removeAll()
    cancelFarTimer()
    signalTimer?.cancel()
    signalTimer = nil
    pollTimer?.cancel()
    pollTimer = nil
    if let central, let peripheral = monitoredPeripheral { central.cancelPeripheralConnection(peripheral) }
    monitoredPeripheral = nil
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
