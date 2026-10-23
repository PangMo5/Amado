// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AmadoKit
import AppKit
import CoreBluetooth
import Dependencies
import DependenciesMacros
import Foundation
import IOBluetooth
import OSLog

// MARK: - DiscoveredDevice

/// One device available to the Settings picker. Continuity devices carry their
/// Core Bluetooth UUID; system-paired devices carry a normalized Classic
/// address. RSSI is nil until a transport exposes a usable negative dBm value.
struct DiscoveredDevice: Equatable, Sendable, Identifiable {
  let id: ProximityDeviceID
  let name: String
  let rssi: Int?
}

// MARK: - ProximityRSSI

enum ProximityRSSI {
  static func continuity(_ value: Int) -> Int? {
    (-110 ... -1).contains(value) ? value : nil
  }

  /// IOBluetooth documents -127...20 with +127 as unavailable, but current
  /// macOS also returns a cached 0 while System Information reports a real
  /// negative RSSI. Keep 0 fail-open, clamp the remaining usable range to the
  /// decision engine's -110...-1 contract, and preserve very weak samples.
  static func classic(_ value: Int) -> Int? {
    guard value != 0, value != 127, (-127 ... 20).contains(value) else { return nil }
    return min(-1, max(-110, value))
  }

  static func classic(_ value: Int, isConnected: Bool) -> Int? {
    isConnected ? classic(value) : nil
  }
}

// MARK: - SignalCheckToken

struct SignalCheckToken: Equatable, Sendable {
  let generation: UInt64
  let epoch: UInt64
}

// MARK: - SignalCheckCoordinator

struct SignalCheckCoordinator: Sendable {

  // MARK: Internal

  mutating func arm(generation: UInt64) -> SignalCheckToken {
    epoch &+= 1
    return SignalCheckToken(generation: generation, epoch: epoch)
  }

  mutating func cancel() {
    epoch &+= 1
  }

  func accepts(_ token: SignalCheckToken, currentGeneration: UInt64) -> Bool {
    token.generation == currentGeneration && token.epoch == epoch
  }

  // MARK: Private

  private var epoch: UInt64 = 0

}

// MARK: - ClassicSignalLossGate

struct ClassicSignalLossGate: Sendable {

  // MARK: Internal

  mutating func linkStarted() {
    hasUsableRSSI = false
  }

  mutating func observedUsableRSSI() {
    hasUsableRSSI = true
  }

  mutating func disconnected() -> Bool {
    defer { hasUsableRSSI = false }
    return hasUsableRSSI
  }

  mutating func reset() {
    hasUsableRSSI = false
  }

  // MARK: Private

  private var hasUsableRSSI = false

}

// MARK: - ClassicConnectionAttempt

struct ClassicConnectionAttempt: Equatable, Sendable {
  let id: UInt64
  let generation: UInt64
  let address: String
}

// MARK: - ClassicConnectionIdentity

enum ClassicConnectionIdentity {
  static let none = BluetoothConnectionHandle(kBluetoothConnectionHandleNone)

  static func matches(
    expected: BluetoothConnectionHandle,
    current: BluetoothConnectionHandle,
    isConnected: Bool,
  ) -> Bool {
    isConnected && expected != none && expected == current
  }
}

// MARK: - ClassicConnectionCompletion

enum ClassicConnectionCompletion: Equatable, Sendable {
  case useOwnedConnection
  case closeStaleOwnedConnection
  case retry
  case ignore
}

// MARK: - ClassicConnectionCoordinator

/// Correlates IOBluetooth's callback-only connection API with the monitor
/// generation that initiated it. It owns no SDK objects and is deterministic
/// under tests; the live engine performs the resulting side effects.
struct ClassicConnectionCoordinator: Sendable {

  // MARK: Internal

  mutating func begin(generation: UInt64, address: String) -> ClassicConnectionAttempt? {
    guard !hasPending(address: address) else { return nil }
    nextAttemptID &+= 1
    let attempt = ClassicConnectionAttempt(
      id: nextAttemptID,
      generation: generation,
      address: address,
    )
    pending[attempt.id] = attempt
    return attempt
  }

  mutating func cancel(_ attempt: ClassicConnectionAttempt) {
    guard pending[attempt.id] == attempt else { return }
    pending.removeValue(forKey: attempt.id)
  }

  mutating func timeOut(
    _ attempt: ClassicConnectionAttempt,
    currentGeneration: UInt64,
    currentAddress: String?,
  ) -> ClassicConnectionCompletion {
    guard pending.removeValue(forKey: attempt.id) == attempt else { return .ignore }
    rememberRetired(attempt)
    let isCurrent =
      attempt.generation == currentGeneration
        && attempt.address == currentAddress
    return isCurrent ? .retry : .ignore
  }

  func hasPending(address: String) -> Bool {
    pending.values.contains { $0.address == address }
  }

  func tracks(attemptID: UInt64) -> Bool {
    pending[attemptID] != nil || retired[attemptID] != nil
  }

  mutating func complete(
    _ attempt: ClassicConnectionAttempt,
    succeeded: Bool,
    isConnected: Bool,
    currentGeneration: UInt64,
    currentAddress: String?,
  ) -> ClassicConnectionCompletion {
    if retired.removeValue(forKey: attempt.id) == attempt {
      guard succeeded, isConnected else { return .ignore }
      return attempt.address == currentAddress
        ? .useOwnedConnection
        : .closeStaleOwnedConnection
    }
    guard pending.removeValue(forKey: attempt.id) == attempt else { return .ignore }
    return resolution(
      for: attempt,
      succeeded: succeeded,
      isConnected: isConnected,
      currentGeneration: currentGeneration,
      currentAddress: currentAddress,
    )
  }

  // MARK: Private

  private var nextAttemptID: UInt64 = 0
  private var pending = [UInt64: ClassicConnectionAttempt]()
  private var retired = [UInt64: ClassicConnectionAttempt]()
  private var retiredOrder = [UInt64]()

  private mutating func rememberRetired(_ attempt: ClassicConnectionAttempt) {
    retired[attempt.id] = attempt
    retiredOrder.append(attempt.id)
    while retiredOrder.count > 32 {
      retired.removeValue(forKey: retiredOrder.removeFirst())
    }
  }

  private func resolution(
    for attempt: ClassicConnectionAttempt,
    succeeded: Bool,
    isConnected: Bool,
    currentGeneration: UInt64,
    currentAddress: String?,
  ) -> ClassicConnectionCompletion {
    if succeeded, isConnected {
      return attempt.address == currentAddress
        ? .useOwnedConnection
        : .closeStaleOwnedConnection
    }
    let isCurrent =
      attempt.generation == currentGeneration
        && attempt.address == currentAddress
    return isCurrent ? .retry : .ignore
  }

}

// MARK: - ClassicLink

struct ClassicLink: Equatable, Sendable {
  let epoch: UInt64
  let generation: UInt64
  let address: String
  let handle: BluetoothConnectionHandle
}

// MARK: - ClassicLinkCoordinator

/// A monitor generation may reconnect several times. The link epoch keeps a
/// delayed poll or disconnect callback from an older physical connection from
/// tearing down the replacement connection.
struct ClassicLinkCoordinator: Sendable {

  // MARK: Internal

  private(set) var active: ClassicLink?

  mutating func activate(
    generation: UInt64,
    address: String,
    handle: BluetoothConnectionHandle,
  ) -> ClassicLink {
    nextEpoch &+= 1
    let link = ClassicLink(
      epoch: nextEpoch,
      generation: generation,
      address: address,
      handle: handle,
    )
    active = link
    return link
  }

  func accepts(_ link: ClassicLink) -> Bool {
    active == link
  }

  mutating func disconnect(_ link: ClassicLink) -> Bool {
    guard active == link else { return false }
    active = nil
    return true
  }

  mutating func invalidate() {
    active = nil
  }

  // MARK: Private

  private var nextEpoch: UInt64 = 0

}

// MARK: - ProximityDeviceCatalog

/// Pure discovery state: short-lived BLE observations and durable paired
/// Classic records have deliberately different lifetimes.
struct ProximityDeviceCatalog: Sendable {

  // MARK: Internal

  mutating func beginScan(pairedDevices: [DiscoveredDevice]) {
    nearby.removeAll()
    replacePairedDevices(pairedDevices)
  }

  mutating func clear() {
    nearby.removeAll()
    paired.removeAll()
  }

  mutating func observeContinuity(
    id: UUID,
    name: String,
    rssi: Int,
    at date: Date,
  ) {
    guard let rssi = ProximityRSSI.continuity(rssi) else { return }
    nearby[id] = (
      device: DiscoveredDevice(id: .continuity(id), name: name, rssi: rssi),
      at: date,
    )
  }

  mutating func replacePairedDevices(_ devices: [DiscoveredDevice]) {
    paired.removeAll(keepingCapacity: true)
    for device in devices where device.id.transport == .classic {
      paired[device.id] = device
    }
  }

  mutating func snapshot(at date: Date, nearbyTTL: TimeInterval) -> [DiscoveredDevice] {
    let cutoff = date.addingTimeInterval(-nearbyTTL)
    nearby = nearby.filter { $0.value.at > cutoff }
    return (nearby.values.map(\.device) + paired.values).sorted(by: Self.areInDisplayOrder)
  }

  func nextNearbyExpiry(nearbyTTL: TimeInterval) -> Date? {
    nearby.values.map { $0.at.addingTimeInterval(nearbyTTL) }.min()
  }

  // MARK: Private

  private var nearby = [UUID: (device: DiscoveredDevice, at: Date)]()
  private var paired = [ProximityDeviceID: DiscoveredDevice]()

  private static func areInDisplayOrder(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
    if lhs.id.transport != rhs.id.transport {
      return lhs.id.transport == .continuity
    }
    switch (lhs.rssi, rhs.rssi) {
    case (.some(let lhsRSSI), .some(let rhsRSSI)) where lhsRSSI != rhsRSSI:
      return lhsRSSI > rhsRSSI
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.id.rawValue < rhs.id.rawValue
    }
  }

}

// MARK: - ProximityFarEvent

struct ProximityFarEvent: Equatable, Sendable {
  let device: ProximityDeviceID
  let session: UInt64
  let reason: ProximityDecisionEngine.LockReason
}

// MARK: - BluetoothUnavailability

/// Why Core Bluetooth cannot be used right now. Kept apart from the generic
/// "waiting" state because turning Bluetooth back on and granting Amado
/// permission are different jobs for the user.
enum BluetoothUnavailability: Equatable, Sendable {
  case poweredOff
  case unauthorized
  case unsupported
  case resetting
  case unknown

  // MARK: Internal

  var summary: String {
    switch self {
    case .poweredOff: "Bluetooth is off"
    case .unauthorized: "Amado isn't allowed to use Bluetooth"
    case .unsupported: "This Mac has no usable Bluetooth"
    case .resetting: "Bluetooth is restarting"
    case .unknown: "Bluetooth is unavailable"
    }
  }

  /// Whether the user has to change something for monitoring to resume. A
  /// restarting radio fixes itself, so it is not worth interrupting anyone.
  var needsUserAction: Bool {
    switch self {
    case .poweredOff,
         .unauthorized: true
    case .resetting,
         .unknown,
         .unsupported: false
    }
  }
}

// MARK: - ProximityStatus

/// Live status of the monitored device, for the Settings status line.
enum ProximityStatus: Equatable, Sendable {
  case disabled
  case waitingForBluetooth(BluetoothUnavailability)
  case connecting
  case connectionUnavailable
  case deviceUnavailable
  case searching
  case learning(rssi: Int?)
  case near(rssi: Int, threshold: Int)
  case leaving(rssi: Int, threshold: Int, secondsRemaining: Int?)
  case reacquiring
  case away(reason: ProximityDecisionEngine.LockReason)
  case signalUnavailable
  case signalLost
}

// MARK: - ProximityStatusEvent

struct ProximityStatusEvent: Equatable, Sendable {
  let device: ProximityDeviceID?
  let session: UInt64
  let status: ProximityStatus
}

// MARK: - ProximityMonitorConfiguration

struct ProximityMonitorConfiguration: Equatable, Sendable {
  let device: ProximityDeviceID?
  let session: UInt64
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

/// The Mac observes either an iPhone's native Continuity BLE advertising or an
/// explicitly system-paired Classic device, then locks when usable RSSI proves
/// that device left. Same-iCloud IRK resolution keeps the app-free iPhone path
/// stable across address rotation. After valid Classic samples arm the engine,
/// link loss uses the same conservative signal-loss confirmation as Continuity;
/// lifecycle and radio resets remain fail-open.
/// Lock-only: no unlock, no stored password.
@DependencyClient
struct ProximityLockClient: Sendable {
  /// Start or refresh monitoring. A nil device stops it.
  var monitor: @Sendable (_ configuration: ProximityMonitorConfiguration) -> Void
  /// Clear smart mode's learned nearby baseline and require stable nearby
  /// observations before re-arming.
  var recalibrate: @Sendable () -> Void
  /// Enter scan mode so `discovered()` lists nearby named BLE advertisements
  /// together with system-paired Classic devices.
  var startScanning: @Sendable () -> Void
  /// Leave scan mode (monitoring, if any, continues).
  var stopScanning: @Sendable () -> Void
  /// BLE results sorted by RSSI, followed by system-paired devices.
  var discovered: @Sendable () -> AsyncStream<[DiscoveredDevice]> = { AsyncStream { _ in } }
  /// One reason each time the monitored device is confirmed gone.
  var farEvents: @Sendable () -> AsyncStream<ProximityFarEvent> = { AsyncStream { _ in } }
  /// Live status of the monitored device, for the Settings status line.
  var status: @Sendable () -> AsyncStream<ProximityStatusEvent> = { AsyncStream { _ in } }
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
private final class ProximityEngine: NSObject,
  CBCentralManagerDelegate,
  CBPeripheralDelegate,
  @unchecked Sendable
{

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
  let farStream: AsyncStream<ProximityFarEvent>
  let statusStream: AsyncStream<ProximityStatusEvent>

  static func unavailability(for state: CBManagerState) -> BluetoothUnavailability {
    switch state {
    case .poweredOff: .poweredOff
    case .unauthorized: .unauthorized
    case .unsupported: .unsupported
    case .resetting: .resetting
    default: .unknown
    }
  }

  func setMonitor(_ configuration: ProximityMonitorConfiguration) {
    queue.async {
      self.connectionGeneration &+= 1
      self.resetConnectionState(clearLearnedBaseline: false)
      self.monitoredDevice = configuration.device
      self.monitorSession = configuration.session
      self.monitorMode = configuration.mode
      self.decisionEngine = ProximityDecisionEngine(configuration: configuration.decisionConfiguration)
      self.ensureManager()
      self.emitStatus(configuration.device == nil ? .disabled : .searching)
      if self.central?.state == .poweredOn {
        self.reacquireMonitored()
        self.applyScan()
      }
    }
  }

  func recalibrate() {
    queue.async {
      guard self.monitoredDevice != nil else { return }
      self.decisionEngine.reset(clearLearnedBaseline: true)
      self.emitStatus(.learning(rssi: nil))
      self.loggerSnapshot(self.decisionEngine.currentSnapshot, event: "recalibrated")
    }
  }

  func setScanMode(_ on: Bool) {
    queue.async {
      self.scanMode = on
      if on {
        self.catalog.beginScan(pairedDevices: self.pairedClassicDevices())
        self.emitDiscoveredSnapshot()
        self.schedulePairedClassicRefresh()
      } else {
        self.discoveredFlush?.cancel()
        self.discoveredFlush = nil
        self.discoveredExpiry?.cancel()
        self.discoveredExpiry = nil
        self.pairedClassicRefresh?.cancel()
        self.pairedClassicRefresh = nil
        self.catalog.clear()
        self.discoveredCont.yield([])
      }
      self.ensureManager()
      self.applyScan()
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    connectionGeneration &+= 1
    if central.state == .poweredOn {
      suspended = false
      decisionEngine.reset(clearLearnedBaseline: false)
      emitStatus(monitoredDevice == nil ? .disabled : .reacquiring)
      reacquireMonitored()
      applyScan()
    } else {
      resetConnectionState(clearLearnedBaseline: false)
      emitStatus(.waitingForBluetooth(Self.unavailability(for: central.state)))
    }
  }

  func centralManager(
    _: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber,
  ) {
    let rssi = RSSI.intValue

    if scanMode, ProximityRSSI.continuity(rssi) != nil {
      let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
      if let name, !name.isEmpty {
        catalog.observeContinuity(
          id: peripheral.identifier,
          name: name,
          rssi: rssi,
          at: Date(),
        )
        scheduleDiscoveredFlush()
      }
    }

    guard monitoredDevice == .continuity(peripheral.identifier) else { return }
    if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
    if !active, ProximityRSSI.continuity(rssi) != nil {
      ingest(rssi)
      connectMonitored()
    }
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard monitoredDevice == .continuity(peripheral.identifier) else { return }
    peripheral.delegate = self
    active = true
    lastReadAt = Date()
    peripheral.readRSSI()
    schedulePoll(peripheral) // self-rearming; survives read errors/stalls
  }

  func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error _: Error?) {
    guard monitoredDevice == .continuity(peripheral.identifier) else { return }
    active = false // stay on the passive scan-RSSI path
  }

  func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
    guard monitoredDevice == .continuity(peripheral.identifier) else { return }
    active = false
    if case .continuity = monitoredDevice { connectMonitored() } // reconnect when back in range
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    // Only record successful reads. The poll loop is driven by `schedulePoll`,
    // NOT rescheduled here — so an errored read can't kill it, and a stalled
    // read lets `lastReadAt` go stale so the stall branch trips.
    guard monitoredDevice == .continuity(peripheral.identifier), error == nil else { return }
    lastReadAt = Date()
    ingest(RSSI.intValue)
  }

  // MARK: Private

  private final class ClassicConnectionObserver: NSObject,
    IOBluetoothDeviceAsyncCallbacks,
    @unchecked Sendable
  {

    // MARK: Lifecycle

    init(owner: ProximityEngine, attempt: ClassicConnectionAttempt) {
      self.owner = owner
      self.attempt = attempt
    }

    // MARK: Internal

    let attempt: ClassicConnectionAttempt
    weak var owner: ProximityEngine?

    func remoteNameRequestComplete(_: IOBluetoothDevice!, status _: IOReturn) { }

    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
      owner?.enqueueClassicConnectionCompletion(
        attempt: attempt,
        status: status,
        handle: device?.connectionHandle ?? ClassicConnectionIdentity.none,
      )
    }

    func sdpQueryComplete(_: IOBluetoothDevice!, status _: IOReturn) { }

  }

  private final class ClassicDisconnectObserver: NSObject, @unchecked Sendable {

    // MARK: Lifecycle

    init(owner: ProximityEngine, link: ClassicLink) {
      self.owner = owner
      self.link = link
    }

    // MARK: Internal

    let link: ClassicLink
    weak var owner: ProximityEngine?

    @objc
    func disconnected(_: IOBluetoothUserNotification, device _: IOBluetoothDevice) {
      owner?.enqueueClassicDisconnect(link: link)
    }

  }

  private static let signalTimeout: TimeInterval = 30
  private static let signalRecheckSeconds: TimeInterval = 15
  private static let rssiPollSeconds: TimeInterval = 1
  private static let activeStallSeconds: TimeInterval = 10
  private static let discoveredTTL: TimeInterval = 5 // drop picker entries not seen recently
  private static let pairedClassicRefreshSeconds: TimeInterval = 1
  private static let classicPageTimeout: BluetoothHCIPageTimeout = 0x2000
  /// HCI page-timeout units are 0.625 ms, so 0x2000 is 5.12 seconds. Give the
  /// documented completion callback a little scheduling margin, then retire
  /// the attempt so a missing callback cannot block this address forever.
  private static let classicConnectionWatchdogSeconds: TimeInterval = 10
  private static let classicReconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30]
  private static let classicUnavailableSampleLimit = 3

  private let queue = DispatchQueue(label: "dev.PangMo5.Amado.proximityLock")
  private var central: CBCentralManager?
  private var monitoredDevice: ProximityDeviceID?
  private var monitoredPeripheral: CBPeripheral?
  /// `IOBluetoothDevice` is non-Sendable. This and every other Classic object
  /// below are touched only on `queue`; callbacks extract address/status value
  /// snapshots before hopping back to that queue.
  private var monitoredClassicDevice: IOBluetoothDevice?
  private var classicDisconnectNotification: IOBluetoothUserNotification?
  private var classicDisconnectObserver: ClassicDisconnectObserver?
  private var classicConnectionCoordinator = ClassicConnectionCoordinator()
  private var classicLinkCoordinator = ClassicLinkCoordinator()
  private var classicConnectionObservers = [UInt64: ClassicConnectionObserver]()
  private var classicConnectionTimeouts = [UInt64: DispatchWorkItem]()
  private var classicReconnectAttempt = 0
  private var classicInvalidSampleCount = 0
  private var classicSignalLossGate = ClassicSignalLossGate()
  private var connectionGeneration: UInt64 = 0
  private var signalCheckCoordinator = SignalCheckCoordinator()
  private var monitorSession: UInt64 = 0
  private var monitorMode = ProximityDetectionMode.smart
  private var decisionEngine = ProximityDecisionEngine(configuration: .init())
  private var active = false
  private var suspended = false
  private var signalTimer: DispatchWorkItem?
  private var manualDecisionTimer: DispatchWorkItem?
  private var pollTimer: DispatchWorkItem?
  private var classicReconnectTimer: DispatchWorkItem?
  private var classicPollTimer: DispatchWorkItem?
  private var scanMode = false
  private var catalog = ProximityDeviceCatalog()
  private var discoveredFlush: DispatchWorkItem?
  private var discoveredExpiry: DispatchWorkItem?
  private var pairedClassicRefresh: DispatchWorkItem?
  private var lastReadAt = Date.distantPast
  private var lastStatusEvent: ProximityStatusEvent?
  private var lastLoggedPhase: ProximityDecisionEngine.Phase?
  private let discoveredCont: AsyncStream<[DiscoveredDevice]>.Continuation
  private let farCont: AsyncStream<ProximityFarEvent>.Continuation
  private let statusCont: AsyncStream<ProximityStatusEvent>.Continuation

  private var currentClassicAddress: String? {
    guard
      !suspended,
      central?.state == .poweredOn,
      case .classic(let address) = monitoredDevice
    else { return nil }
    return address
  }

  private static func makeStream<T>() -> (AsyncStream<T>, AsyncStream<T>.Continuation) {
    var continuation: AsyncStream<T>.Continuation!
    let stream = AsyncStream<T>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    return (stream, continuation)
  }

  private static func systemPairedDevices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
  }

  private func ingest(_ rssi: Int) {
    guard let rssi = ProximityRSSI.continuity(rssi), !suspended else { return }
    let evaluation = decisionEngine.ingest(
      rssi: rssi,
      at: ProcessInfo.processInfo.systemUptime,
    )
    apply(evaluation)
    switch monitoredDevice {
    case .continuity:
      scheduleSignalCheck(after: Self.signalTimeout)
    case .classic:
      // A valid sample from a reconnected Classic link disproves the pending
      // loss. Classic arms a fresh timer only from its disconnect callback.
      cancelSignalCheck()
    case nil:
      break
    }
  }

  private func scheduleSignalCheck(
    after delay: TimeInterval,
    lossBeganAt: TimeInterval? = nil,
  ) {
    signalTimer?.cancel()
    let token = signalCheckCoordinator.arm(generation: connectionGeneration)
    let work = DispatchWorkItem { [weak self] in
      guard
        let self,
        signalCheckCoordinator.accepts(
          token,
          currentGeneration: connectionGeneration,
        ),
        monitoredDevice != nil,
        !suspended,
        central?.state == .poweredOn
      else { return }
      let evaluation = decisionEngine.signalLost(
        at: ProcessInfo.processInfo.systemUptime,
        lossBeganAt: lossBeganAt,
      )
      apply(evaluation)
      if evaluation.lockReason == nil {
        scheduleSignalCheck(
          after: Self.signalRecheckSeconds,
          lossBeganAt: lossBeganAt,
        )
      }
    }
    signalTimer = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func cancelSignalCheck() {
    signalCheckCoordinator.cancel()
    signalTimer?.cancel()
    signalTimer = nil
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

    let generation = connectionGeneration
    let work = DispatchWorkItem { [weak self] in
      guard
        let self,
        generation == connectionGeneration,
        monitoredDevice != nil,
        !suspended
      else { return }
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
    guard let monitoredDevice, !MacSessionState.isLocked() else { return }
    farCont.yield(
      ProximityFarEvent(
        device: monitoredDevice,
        session: monitorSession,
        reason: reason,
      )
    )
  }

  private func ensureManager() {
    if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
  }

  private func reacquireMonitored() {
    guard let central, central.state == .poweredOn, let monitoredDevice else { return }
    switch monitoredDevice {
    case .continuity(let id):
      if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
        monitoredPeripheral = peripheral
        connectMonitored()
      }

    case .classic(let address):
      connectClassic(address: address, generation: connectionGeneration)
    }
  }

  private func connectMonitored() {
    guard
      let central,
      central.state == .poweredOn,
      !suspended,
      let peripheral = monitoredPeripheral,
      monitoredDevice == .continuity(peripheral.identifier),
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
    let generation = connectionGeneration
    let work = DispatchWorkItem { [weak self, weak peripheral] in
      guard
        let self,
        let peripheral,
        generation == connectionGeneration,
        active,
        monitoredDevice == .continuity(peripheral.identifier)
      else { return }
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

  private func pairedClassicDevices() -> [DiscoveredDevice] {
    Self.systemPairedDevices().compactMap { device in
      guard
        let rawAddress = device.addressString,
        let id = ProximityDeviceID(transport: .classic, rawValue: rawAddress)
      else { return nil }
      let isConnected = device.isConnected()
      return DiscoveredDevice(
        id: id,
        name: device.nameOrAddress ?? id.rawValue,
        rssi: ProximityRSSI.classic(
          isConnected ? Int(device.rawRSSI()) : 0,
          isConnected: isConnected,
        ),
      )
    }
  }

  private func pairedClassicDevice(address: String) -> IOBluetoothDevice? {
    Self.systemPairedDevices().first { device in
      guard let rawAddress = device.addressString else { return false }
      return ProximityDeviceID(transport: .classic, rawValue: rawAddress) == .classic(address)
    }
  }

  private func classicDevice(address: String) -> IOBluetoothDevice? {
    pairedClassicDevice(address: address) ?? IOBluetoothDevice(addressString: address)
  }

  private func connectClassic(address: String, generation: UInt64) {
    guard
      generation == connectionGeneration,
      monitoredDevice == .classic(address),
      !suspended,
      central?.state == .poweredOn
    else { return }
    guard let device = pairedClassicDevice(address: address) else {
      emitStatus(.deviceUnavailable)
      scheduleClassicReconnect(generation: generation)
      return
    }

    monitoredClassicDevice = device
    if device.isConnected() {
      if
        let activeLink = classicLinkCoordinator.active,
        activeLink.generation == generation,
        activeLink.address == address
      {
        if
          ClassicConnectionIdentity.matches(
            expected: activeLink.handle,
            current: device.connectionHandle,
            isConnected: true,
          )
        {
          return
        }
        handleClassicDisconnect(link: activeLink)
      }
      // `isPaired` identifies a stored record, not whether this particular ACL
      // link authenticated. Only a success callback from Amado's own
      // authentication-required open is allowed to feed the lock engine.
      emitStatus(.connectionUnavailable)
      scheduleClassicReconnect(generation: generation)
      return
    }

    if classicConnectionCoordinator.hasPending(address: address) {
      emitStatus(.connecting)
      scheduleClassicReconnect(generation: generation)
      return
    }
    guard
      let attempt = classicConnectionCoordinator.begin(
        generation: generation,
        address: address,
      )
    else { return }
    let observer = ClassicConnectionObserver(owner: self, attempt: attempt)
    classicConnectionObservers[attempt.id] = observer
    emitStatus(.connecting)
    let result = device.openConnection(
      observer,
      withPageTimeout: Self.classicPageTimeout,
      authenticationRequired: true,
    )
    guard result == kIOReturnSuccess else {
      classicConnectionCoordinator.cancel(attempt)
      classicConnectionObservers.removeValue(forKey: attempt.id)
      emitStatus(.reacquiring)
      scheduleClassicReconnect(
        generation: generation,
        persistentFailure: .connectionUnavailable,
      )
      return
    }
    let timeout = DispatchWorkItem { [weak self] in
      self?.handleClassicConnectionTimeout(attempt: attempt)
    }
    classicConnectionTimeouts[attempt.id] = timeout
    queue.asyncAfter(
      deadline: .now() + Self.classicConnectionWatchdogSeconds,
      execute: timeout,
    )
    scheduleClassicReconnect(generation: generation)
  }

  private func scheduleClassicReconnect(
    generation: UInt64,
    persistentFailure: ProximityStatus? = nil,
  ) {
    guard
      generation == connectionGeneration,
      case .classic = monitoredDevice,
      !suspended
    else { return }
    classicReconnectTimer?.cancel()
    let index = min(classicReconnectAttempt, Self.classicReconnectDelays.count - 1)
    let delay = Self.classicReconnectDelays[index]
    classicReconnectAttempt += 1
    if classicReconnectAttempt >= 4, let persistentFailure {
      emitStatus(persistentFailure)
    }
    let work = DispatchWorkItem { [weak self] in
      guard
        let self,
        generation == connectionGeneration,
        case .classic(let address) = monitoredDevice,
        !suspended
      else { return }
      connectClassic(address: address, generation: generation)
    }
    classicReconnectTimer = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func startClassicPolling(
    device: IOBluetoothDevice,
    generation: UInt64,
    handle: BluetoothConnectionHandle,
  ) {
    guard
      generation == connectionGeneration,
      case .classic(let address) = monitoredDevice,
      device.isPaired(),
      ClassicConnectionIdentity.matches(
        expected: handle,
        current: device.connectionHandle,
        isConnected: device.isConnected(),
      ),
      device.addressString.flatMap({ ProximityDeviceID(transport: .classic, rawValue: $0) }) == .classic(address)
    else { return }

    classicReconnectAttempt = 0
    classicInvalidSampleCount = 0
    classicSignalLossGate.linkStarted()
    classicReconnectTimer?.cancel()
    classicReconnectTimer = nil
    cancelSignalCheck()
    classicDisconnectNotification?.unregister()
    let link = classicLinkCoordinator.activate(
      generation: generation,
      address: address,
      handle: handle,
    )
    let disconnectObserver = ClassicDisconnectObserver(owner: self, link: link)
    classicDisconnectObserver = disconnectObserver
    classicDisconnectNotification = device.register(
      forDisconnectNotification: disconnectObserver,
      selector: #selector(ClassicDisconnectObserver.disconnected(_:device:)),
    )
    emitStatus(status(for: decisionEngine.currentSnapshot))
    pollClassic(device: device, link: link)
  }

  private func pollClassic(device: IOBluetoothDevice, link: ClassicLink) {
    classicPollTimer?.cancel()
    guard
      classicLinkCoordinator.accepts(link),
      link.generation == connectionGeneration,
      monitoredDevice == .classic(link.address),
      !suspended
    else { return }
    guard
      ClassicConnectionIdentity.matches(
        expected: link.handle,
        current: device.connectionHandle,
        isConnected: device.isConnected(),
      )
    else {
      handleClassicDisconnect(link: link)
      return
    }

    if let rssi = ProximityRSSI.classic(Int(device.rawRSSI())) {
      classicInvalidSampleCount = 0
      classicSignalLossGate.observedUsableRSSI()
      ingest(rssi)
    } else {
      ingestUnavailableClassicSample()
    }

    let work = DispatchWorkItem { [weak self] in
      guard let self, let device = monitoredClassicDevice else { return }
      pollClassic(device: device, link: link)
    }
    classicPollTimer = work
    queue.asyncAfter(deadline: .now() + Self.rssiPollSeconds, execute: work)
  }

  private func ingestUnavailableClassicSample() {
    classicInvalidSampleCount += 1
    cancelSignalCheck()
    manualDecisionTimer?.cancel()
    manualDecisionTimer = nil
    if classicInvalidSampleCount == Self.classicUnavailableSampleLimit {
      emitStatus(.signalUnavailable)
    }
  }

  private func enqueueClassicConnectionCompletion(
    attempt: ClassicConnectionAttempt,
    status: IOReturn,
    handle: BluetoothConnectionHandle,
  ) {
    queue.async {
      self.handleClassicConnectionCompletion(
        attempt: attempt,
        status: status,
        handle: handle,
      )
    }
  }

  private func handleClassicConnectionCompletion(
    attempt: ClassicConnectionAttempt,
    status: IOReturn,
    handle: BluetoothConnectionHandle,
  ) {
    classicConnectionTimeouts.removeValue(forKey: attempt.id)?.cancel()
    classicConnectionObservers.removeValue(forKey: attempt.id)
    let device = classicDevice(address: attempt.address)
    let completion = classicConnectionCoordinator.complete(
      attempt,
      succeeded: status == kIOReturnSuccess,
      isConnected: device.map {
        ClassicConnectionIdentity.matches(
          expected: handle,
          current: $0.connectionHandle,
          isConnected: $0.isConnected(),
        )
      } ?? false,
      currentGeneration: connectionGeneration,
      currentAddress: currentClassicAddress,
    )
    applyClassicConnectionCompletion(
      completion,
      attempt: attempt,
      device: device,
      handle: handle,
      timedOut: false,
    )
    pruneClassicConnectionObservers()
  }

  private func handleClassicConnectionTimeout(attempt: ClassicConnectionAttempt) {
    classicConnectionTimeouts.removeValue(forKey: attempt.id)
    let device = classicDevice(address: attempt.address)
    let completion = classicConnectionCoordinator.timeOut(
      attempt,
      currentGeneration: connectionGeneration,
      currentAddress: currentClassicAddress,
    )
    applyClassicConnectionCompletion(
      completion,
      attempt: attempt,
      device: device,
      handle: ClassicConnectionIdentity.none,
      timedOut: true,
    )
    pruneClassicConnectionObservers()
  }

  private func applyClassicConnectionCompletion(
    _ completion: ClassicConnectionCompletion,
    attempt: ClassicConnectionAttempt,
    device: IOBluetoothDevice?,
    handle: BluetoothConnectionHandle,
    timedOut: Bool,
  ) {
    switch completion {
    case .useOwnedConnection:
      if
        let activeLink = classicLinkCoordinator.active,
        activeLink.address == attempt.address,
        activeLink.handle == handle
      {
        // A newer successful attempt already owns the current device-wide link.
        return
      }
      guard let device, device.isPaired() else {
        if let device {
          closeClassicConnectionOpenedByAmado(
            device,
            address: attempt.address,
            expectedHandle: handle,
            reason: "device became unpaired",
          )
        }
        emitStatus(.deviceUnavailable)
        scheduleClassicReconnect(generation: connectionGeneration)
        return
      }
      monitoredClassicDevice = device
      startClassicPolling(
        device: device,
        generation: connectionGeneration,
        handle: handle,
      )

    case .closeStaleOwnedConnection:
      if let device {
        closeClassicConnectionOpenedByAmado(
          device,
          address: attempt.address,
          expectedHandle: handle,
          reason: "stale connection attempt completed",
        )
      }

    case .retry:
      if classicLinkCoordinator.active?.address == attempt.address { return }
      if timedOut {
        classicReconnectAttempt = 0
        emitStatus(.connectionUnavailable)
      } else {
        emitStatus(.reacquiring)
      }
      scheduleClassicReconnect(
        generation: connectionGeneration,
        persistentFailure: timedOut ? nil : .connectionUnavailable,
      )

    case .ignore:
      break
    }
  }

  private func pruneClassicConnectionObservers() {
    for attemptID in Array(classicConnectionObservers.keys)
      where !classicConnectionCoordinator.tracks(attemptID: attemptID)
    {
      classicConnectionObservers.removeValue(forKey: attemptID)
    }
  }

  private func closeClassicConnectionOpenedByAmado(
    _ device: IOBluetoothDevice,
    address: String,
    expectedHandle: BluetoothConnectionHandle,
    reason: String,
  ) {
    guard
      ClassicConnectionIdentity.matches(
        expected: expectedHandle,
        current: device.connectionHandle,
        isConnected: device.isConnected(),
      )
    else { return }
    // Baseband links are device-wide, not reference-counted per client. Make
    // the required best-effort close once, but never retry a failure later when
    // the same handle may already belong to a replacement/borrowed link.
    let result = device.closeConnection()
    if result != kIOReturnSuccess, device.isConnected() {
      logger.error(
        "proximity: failed to close owned Classic connection address=\(address, privacy: .private(mask: .hash)) reason=\(reason, privacy: .public) status=\(result)"
      )
    }
  }

  private func enqueueClassicDisconnect(link: ClassicLink) {
    queue.async {
      self.handleClassicDisconnect(link: link)
    }
  }

  private func handleClassicDisconnect(link: ClassicLink) {
    guard
      classicLinkCoordinator.disconnect(link),
      link.generation == connectionGeneration,
      monitoredDevice == .classic(link.address)
    else { return }
    classicDisconnectNotification?.unregister()
    classicDisconnectNotification = nil
    classicDisconnectObserver = nil
    classicPollTimer?.cancel()
    classicPollTimer = nil
    let shouldConfirmLoss = classicSignalLossGate.disconnected()
    manualDecisionTimer?.cancel()
    manualDecisionTimer = nil
    classicInvalidSampleCount = 0
    emitStatus(.reacquiring)
    if shouldConfirmLoss {
      scheduleSignalCheck(
        after: Self.signalTimeout,
        lossBeganAt: ProcessInfo.processInfo.systemUptime,
      )
    } else {
      cancelSignalCheck()
    }
    scheduleClassicReconnect(generation: link.generation)
  }

  private func applyScan() {
    guard let central, central.state == .poweredOn, !suspended else { return }
    let monitorsContinuity = monitoredDevice?.transport == .continuity
    let wants = scanMode || monitorsContinuity
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
    let ownedClassicLink = classicLinkCoordinator.active
    let ownedClassicDevice = ownedClassicLink == nil ? nil : monitoredClassicDevice
    active = false
    decisionEngine.reset(clearLearnedBaseline: clearLearnedBaseline)
    cancelSignalCheck()
    manualDecisionTimer?.cancel()
    manualDecisionTimer = nil
    pollTimer?.cancel()
    pollTimer = nil
    classicReconnectTimer?.cancel()
    classicReconnectTimer = nil
    classicPollTimer?.cancel()
    classicPollTimer = nil
    classicDisconnectNotification?.unregister()
    classicDisconnectNotification = nil
    classicDisconnectObserver = nil
    classicLinkCoordinator.invalidate()
    if let central, let peripheral = monitoredPeripheral { central.cancelPeripheralConnection(peripheral) }
    if let link = ownedClassicLink, let device = ownedClassicDevice {
      closeClassicConnectionOpenedByAmado(
        device,
        address: monitoredDevice?.rawValue ?? device.addressString ?? "unknown",
        expectedHandle: link.handle,
        reason: "monitor reset",
      )
    }
    monitoredPeripheral = nil
    monitoredClassicDevice = nil
    classicReconnectAttempt = 0
    classicInvalidSampleCount = 0
    classicSignalLossGate.reset()
    lastLoggedPhase = nil
  }

  @objc
  private func workspaceWillSleep(_: Notification) {
    queue.async {
      self.connectionGeneration &+= 1
      self.suspended = true
      self.central?.stopScan()
      self.resetConnectionState(clearLearnedBaseline: false)
      self.emitStatus(self.monitoredDevice == nil ? .disabled : .reacquiring)
    }
  }

  @objc
  private func workspaceDidWake(_: Notification) {
    queue.async {
      self.connectionGeneration &+= 1
      self.suspended = false
      self.resetConnectionState(clearLearnedBaseline: false)
      self.emitStatus(self.monitoredDevice == nil ? .disabled : .reacquiring)
      self.reacquireMonitored()
      self.applyScan()
    }
  }

  private func scheduleDiscoveredFlush() {
    guard discoveredFlush == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      discoveredFlush = nil
      emitDiscoveredSnapshot()
    }
    discoveredFlush = work
    queue.asyncAfter(deadline: .now() + 0.5, execute: work) // debounce the allowDuplicates flood
  }

  private func schedulePairedClassicRefresh() {
    pairedClassicRefresh?.cancel()
    guard scanMode else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, scanMode else { return }
      pairedClassicRefresh = nil
      catalog.replacePairedDevices(pairedClassicDevices())
      emitDiscoveredSnapshot()
      schedulePairedClassicRefresh()
    }
    pairedClassicRefresh = work
    queue.asyncAfter(
      deadline: .now() + Self.pairedClassicRefreshSeconds,
      execute: work,
    )
  }

  private func emitDiscoveredSnapshot() {
    guard scanMode else { return }
    let now = Date()
    discoveredCont.yield(catalog.snapshot(at: now, nearbyTTL: Self.discoveredTTL))
    discoveredExpiry?.cancel()
    discoveredExpiry = nil
    guard let expiry = catalog.nextNearbyExpiry(nearbyTTL: Self.discoveredTTL) else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      discoveredExpiry = nil
      emitDiscoveredSnapshot()
    }
    discoveredExpiry = work
    queue.asyncAfter(
      deadline: .now() + max(0.05, expiry.timeIntervalSince(now)),
      execute: work,
    )
  }

  private func emitStatus(_ status: ProximityStatus) {
    let event = ProximityStatusEvent(
      device: monitoredDevice,
      session: monitorSession,
      status: status,
    )
    guard event != lastStatusEvent else { return }
    lastStatusEvent = event
    statusCont.yield(event)
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "ProximityLock")
