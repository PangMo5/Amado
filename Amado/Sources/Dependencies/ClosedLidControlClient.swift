// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog
import ServiceManagement

// MARK: - ClosedLidControlStatus

/// The truth about the system-level closed-lid override, kept separate from
/// the persisted user preference so the UI cannot claim an inactive helper is
/// working.
enum ClosedLidControlStatus: Equatable, Sendable {
  case inactive
  case active
  case helperNotInstalled
  case requiresApproval
  case unsupported
  case failed(String)

  var summary: String {
    switch self {
    case .inactive: "Off"
    case .active: "Active"
    case .helperNotInstalled: "Install the Power Helper to use Caffeinate"
    case .requiresApproval: "Approve the Power Helper in Login Items & Extensions"
    case .unsupported: "This Mac has no built-in lid"
    case .failed(let reason): "Unavailable: \(reason)"
    }
  }
}

// MARK: - PowerHelperInstallationStatus

/// The launchd registration state is independent from whether Caffeinate is
/// currently active. Keeping it explicit prevents the UI from presenting an
/// unregistered helper as merely inactive.
enum PowerHelperInstallationStatus: Equatable, Sendable {
  case checking
  case notInstalled
  case requiresApproval
  case installed(PowerHelperBuild)
  case updateAvailable(installed: PowerHelperBuild?, bundled: PowerHelperBuild)
  case failed(reason: String, isRegistered: Bool)

  // MARK: Internal

  var summary: String {
    switch self {
    case .checking:
      "Checking…"
    case .notInstalled:
      "Not installed"
    case .requiresApproval:
      "Waiting for approval in Login Items & Extensions"
    case .installed(let build):
      "Installed — version \(build.displayName)"
    case .updateAvailable(let installed, let bundled):
      "Update available — \(installed?.displayName ?? "unknown") → \(bundled.displayName)"
    case .failed(let reason, _):
      "Unavailable: \(reason)"
    }
  }

  var canInstall: Bool {
    switch self {
    case .notInstalled,
         .updateAvailable:
      true
    case .checking,
         .requiresApproval,
         .installed,
         .failed:
      false
    }
  }

  var canRemove: Bool {
    switch self {
    case .requiresApproval,
         .installed,
         .updateAvailable:
      true
    case .failed(_, let isRegistered):
      isRegistered
    case .checking,
         .notInstalled:
      false
    }
  }

  var isReady: Bool {
    if case .installed = self { return true }
    return false
  }

  var installButtonTitle: String {
    if case .updateAvailable = self { return "Update Power Helper" }
    return "Install Power Helper"
  }

  var diagnostic: String {
    if case .failed(let reason, _) = self { return reason }
    return summary
  }
}

// MARK: - BuiltinDisplayDimmingResult

enum BuiltinDisplayDimmingResult: Equatable, Sendable {
  case applied
  case failed(String)
}

// MARK: - DisplaySleepResult

enum DisplaySleepResult: Equatable, Sendable {
  case applied
  case failed(String)
}

// MARK: - ClosedLidControlClient

/// Controls the privileged clamshell-sleep override and publishes physical lid
/// transitions. Enabling requires the bundled, user-approved root helper;
/// ordinary IOKit assertions cannot override lid-close sleep.
@DependencyClient
struct ClosedLidControlClient: Sendable {
  var setEnabled: @Sendable (_ enabled: Bool) async -> ClosedLidControlStatus = {
    enabled in enabled ? .unsupported : .inactive
  }

  var helperStatus: @Sendable () async -> PowerHelperInstallationStatus = { .notInstalled }
  var installHelper: @Sendable () async -> PowerHelperInstallationStatus = { .notInstalled }
  var removeHelper: @Sendable () async -> PowerHelperInstallationStatus = { .notInstalled }
  var openHelperSettings: @Sendable () async -> Void
  var setBuiltinDisplayDimmed: @Sendable (_ dimmed: Bool) async -> BuiltinDisplayDimmingResult = {
    _ in .applied
  }

  var sleepDisplays: @Sendable () async -> DisplaySleepResult = { .applied }

  var lidChanges: @Sendable () -> AsyncStream<Bool> = { AsyncStream { $0.finish() } }
  var statusChanges: @Sendable () -> AsyncStream<ClosedLidControlStatus> = { AsyncStream { $0.finish() } }
}

// MARK: DependencyKey

extension ClosedLidControlClient: DependencyKey {
  static let liveValue: ClosedLidControlClient = {
    let controller = ClosedLidController.shared
    let lidMonitor = LidMonitor.shared
    return ClosedLidControlClient(
      setEnabled: { enabled in await controller.setEnabled(enabled) },
      helperStatus: { await controller.helperStatus() },
      installHelper: { await controller.installHelper() },
      removeHelper: { await controller.removeHelper() },
      openHelperSettings: { await controller.openHelperSettings() },
      setBuiltinDisplayDimmed: { dimmed in await controller.setBuiltinDisplayDimmed(dimmed) },
      sleepDisplays: { await controller.sleepDisplays() },
      lidChanges: { lidMonitor.changes },
      statusChanges: { controller.statusChanges },
    )
  }()

  static let testValue = ClosedLidControlClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var closedLidControl: ClosedLidControlClient {
    get { self[ClosedLidControlClient.self] }
    set { self[ClosedLidControlClient.self] = newValue }
  }
}

// MARK: - ClosedLidController

private actor ClosedLidController {

  // MARK: Lifecycle

  private init() {
    var continuation: AsyncStream<ClosedLidControlStatus>.Continuation!
    statusChanges = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    statusContinuation = continuation
  }

  // MARK: Internal

  static let shared = ClosedLidController()

  nonisolated let statusChanges: AsyncStream<ClosedLidControlStatus>

  func setEnabled(_ enabled: Bool) async -> ClosedLidControlStatus {
    guard LidMonitor.isSupported else {
      assertion.release()
      return enabled ? .unsupported : .inactive
    }

    if enabled {
      let readiness = caffeinateReadiness()
      guard readiness == .active else { return readiness }
      guard let connection = makeConnection() else {
        return .failed("The Power Helper connection could not be secured")
      }
      let expectedBuild = PowerHelperBuild.current
      guard expectedBuild.isValid else {
        tearDownConnection()
        return .failed("Amado could not identify its bundled Power Helper")
      }
      let installedBuild = await build(over: connection)
      if installedBuild != expectedBuild {
        let installedBuildName = installedBuild?.displayName ?? "no build response"
        logger.error(
          "Power Helper build mismatch: expected \(expectedBuild.displayName, privacy: .public), received \(installedBuildName, privacy: .public)"
        )
        tearDownConnection()
        return .failed("Update the installed Power Helper in Caffeinate Settings")
      }
      guard await send(enabled: true, over: connection) else {
        tearDownConnection()
        return .failed("The Power Helper did not accept the sleep override")
      }
      guard assertion.acquire() else {
        _ = await send(enabled: false, over: connection)
        tearDownConnection()
        return .failed("macOS refused Amado's idle-sleep assertion")
      }
      return .active
    }

    // Connect even if this process does not currently own a connection. This
    // lets an explicit Off repair a stale global override before releasing the
    // app's ordinary idle-sleep assertion.
    if helperService.status == .enabled {
      guard let connection = makeConnection() else {
        return .failed("The Power Helper connection could not be secured")
      }
      guard await send(enabled: false, over: connection) else {
        return .failed("The Power Helper could not restore normal sleep")
      }
    }
    assertion.release()
    tearDownConnection()
    return .inactive
  }

  func helperStatus() async -> PowerHelperInstallationStatus {
    switch helperService.status {
    case .enabled:
      let bundled = PowerHelperBuild.current
      guard bundled.isValid else {
        return .failed(
          reason: "Amado could not identify its bundled Power Helper",
          isRegistered: true,
        )
      }
      guard let connection = makeConnection() else {
        return .failed(
          reason: "The Power Helper connection could not be secured",
          isRegistered: true,
        )
      }
      guard let installed = await build(over: connection) else {
        tearDownConnection()
        // Helpers from before the build handshake cannot identify themselves,
        // but they are still registered and can be replaced explicitly.
        return .updateAvailable(installed: nil, bundled: bundled)
      }
      tearDownConnection()
      return installed == bundled
        ? .installed(installed)
        : .updateAvailable(installed: installed, bundled: bundled)

    case .requiresApproval:
      return .requiresApproval

    case .notRegistered:
      return .notInstalled

    case .notFound:
      return .failed(reason: "The bundled Power Helper is missing", isRegistered: false)

    @unknown default:
      return .failed(reason: "macOS returned an unknown Power Helper state", isRegistered: false)
    }
  }

  func installHelper() async -> PowerHelperInstallationStatus {
    let status = await helperStatus()
    switch status {
    case .installed,
         .requiresApproval:
      return status

    case .updateAvailable:
      if let connection = makeConnection() {
        _ = await send(enabled: false, over: connection)
      }
      assertion.release()
      tearDownConnection()
      return await replaceRegisteredHelper()

    case .notInstalled:
      return await registerHelper()

    case .checking:
      return await helperStatus()

    case .failed(let reason, let isRegistered):
      return .failed(reason: reason, isRegistered: isRegistered)
    }
  }

  func removeHelper() async -> PowerHelperInstallationStatus {
    // Tell a responsive helper to restore normal sleep first. Unregistering is
    // still authoritative: launchd terminates the daemon, whose SIGTERM path
    // also clears the global override before the completion handler returns.
    if helperService.status == .enabled, let connection = makeConnection() {
      if !(await send(enabled: false, over: connection)) {
        logger.warning("Power Helper did not acknowledge Off before removal")
      }
    }
    assertion.release()
    tearDownConnection()
    _ = await builtinDisplayBacklight.setDimmed(false)

    switch helperService.status {
    case .notRegistered,
         .notFound:
      statusContinuation.yield(.inactive)
      return .notInstalled

    case .enabled,
         .requiresApproval:
      do {
        try await helperService.unregister()
        statusContinuation.yield(.inactive)
        return .notInstalled
      } catch {
        if helperService.status == .notRegistered || helperService.status == .notFound {
          statusContinuation.yield(.inactive)
          return .notInstalled
        }
        let nsError = error as NSError
        logger.error(
          "Power Helper removal failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) — \(nsError.localizedDescription, privacy: .public)"
        )
        return .failed(
          reason: "Power Helper removal failed (\(nsError.domain) \(nsError.code)): "
            + nsError.localizedDescription,
          isRegistered: true,
        )
      }

    @unknown default:
      return .failed(
        reason: "macOS returned an unknown Power Helper state during removal",
        isRegistered: true,
      )
    }
  }

  func openHelperSettings() async {
    await MainActor.run { SMAppService.openSystemSettingsLoginItems() }
  }

  func setBuiltinDisplayDimmed(_ dimmed: Bool) async -> BuiltinDisplayDimmingResult {
    await builtinDisplayBacklight.setDimmed(dimmed)
  }

  func sleepDisplays() -> DisplaySleepResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["displaysleepnow"]
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        return .failed("Display sleep failed with status \(process.terminationStatus)")
      }
      return .applied
    } catch {
      return .failed("Display sleep failed: \(error.localizedDescription)")
    }
  }

  // MARK: Private

  private let assertion = IdleSleepAssertion()
  private let builtinDisplayBacklight = BuiltinDisplayBacklight()
  private let helperService = SMAppService.daemon(plistName: PowerHelperConstants.plistName)
  private let statusContinuation: AsyncStream<ClosedLidControlStatus>.Continuation
  private var connection: NSXPCConnection?
  private var connectionID: UUID?

  private func caffeinateReadiness() -> ClosedLidControlStatus {
    switch helperService.status {
    case .enabled:
      return .active

    case .requiresApproval:
      return .requiresApproval

    case .notRegistered:
      return .helperNotInstalled

    case .notFound:
      return .failed("The bundled Power Helper is missing")

    @unknown default:
      return .failed("macOS returned an unknown Power Helper state")
    }
  }

  private func registerHelper() async -> PowerHelperInstallationStatus {
    do {
      try helperService.register()
    } catch {
      if helperService.status == .requiresApproval {
        return .requiresApproval
      }
      let nsError = error as NSError
      logger.error(
        "Power Helper registration failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) — \(nsError.localizedDescription, privacy: .public)"
      )
      return .failed(
        reason: "Power Helper installation failed (\(nsError.domain) \(nsError.code)): "
          + nsError.localizedDescription,
        isRegistered: helperService.status != .notRegistered && helperService.status != .notFound,
      )
    }
    return await helperStatus()
  }

  private func replaceRegisteredHelper() async -> PowerHelperInstallationStatus {
    do {
      try await helperService.unregister()
    } catch {
      guard helperService.status == .notRegistered || helperService.status == .notFound else {
        let nsError = error as NSError
        logger.error(
          "Old Power Helper removal failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) — \(nsError.localizedDescription, privacy: .public)"
        )
        return .failed(
          reason: "The old Power Helper could not be replaced (\(nsError.domain) \(nsError.code)): "
            + nsError.localizedDescription,
          isRegistered: true,
        )
      }
    }
    return await registerHelper()
  }

  private func makeConnection() -> NSXPCConnection? {
    if let connection { return connection }
    guard
      let requirement = PowerHelperCodeSigning.sameTeamRequirement(
        identifiers: [PowerHelperConstants.helperIdentifier]
      )
    else { return nil }

    let identifier = UUID()
    let connection = NSXPCConnection(
      machServiceName: PowerHelperConstants.machServiceName,
      options: .privileged,
    )
    connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
    connection.setCodeSigningRequirement(requirement)
    connection.interruptionHandler = { [weak self] in
      Task { await self?.connectionEnded(identifier: identifier) }
    }
    connection.invalidationHandler = { [weak self] in
      Task { await self?.connectionEnded(identifier: identifier) }
    }
    connection.resume()
    self.connection = connection
    connectionID = identifier
    return connection
  }

  private func send(enabled: Bool, over connection: NSXPCConnection) async -> Bool {
    let replies = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        logger.error("Power Helper XPC error: \(error.localizedDescription, privacy: .public)")
        continuation.yield(false)
        continuation.finish()
      } as? PowerHelperProtocol
      guard let proxy else {
        continuation.yield(false)
        continuation.finish()
        return
      }
      proxy.setClosedLidMode(enabled) { success in
        continuation.yield(success)
        continuation.finish()
      }
    }
    for await reply in replies {
      return reply
    }
    return false
  }

  private func build(over connection: NSXPCConnection) async -> PowerHelperBuild? {
    let replies = AsyncStream<PowerHelperBuild?>(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        logger.error("Power Helper build handshake failed: \(error.localizedDescription, privacy: .public)")
        continuation.yield(nil)
        continuation.finish()
      } as? PowerHelperProtocol
      guard let proxy else {
        continuation.yield(nil)
        continuation.finish()
        return
      }
      proxy.getBuild { version, build in
        continuation.yield(PowerHelperBuild(version: version, build: build))
        continuation.finish()
      }
      Task {
        try? await Task.sleep(for: .seconds(2))
        continuation.yield(nil)
        continuation.finish()
      }
    }
    for await reply in replies {
      return reply
    }
    return nil
  }

  private func tearDownConnection() {
    let oldConnection = connection
    connection = nil
    connectionID = nil
    oldConnection?.invalidate()
  }

  private func connectionEnded(identifier: UUID) {
    guard identifier == connectionID else { return }
    connection = nil
    connectionID = nil
    assertion.release()
    statusContinuation.yield(.failed("The Power Helper disconnected; normal lid sleep was restored"))
  }

}

// MARK: - BuiltinDisplayBacklight

/// Sets only the built-in panel's backlight to zero. System display sleep is
/// intentionally not used here: with an immediate password policy macOS also
/// locks the login session, which would violate the unlocked closed-lid mode.
///
/// DisplayServices is loaded at runtime because macOS does not publish a
/// supported API for changing a display's hardware brightness. Failures are
/// returned to the feature rather than hidden behind a fallback that changes
/// the requested lock policy.
private final class BuiltinDisplayBacklight: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    framework = dlopen(
      "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
      RTLD_NOW | RTLD_LOCAL,
    )
    getBrightness = framework
      .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
      .map { unsafeBitCast($0, to: GetBrightness.self) }
    setBrightness = framework
      .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
      .map { unsafeBitCast($0, to: SetBrightness.self) }
  }

  deinit {
    if let framework { dlclose(framework) }
  }

  // MARK: Internal

  func setDimmed(_ dimmed: Bool) async -> BuiltinDisplayDimmingResult {
    guard framework != nil, let getBrightness, let setBrightness else {
      return .failed("macOS did not provide the built-in display brightness controls")
    }

    if dimmed {
      guard let displayID = builtinDisplayID() else {
        return .failed("The built-in display could not be found")
      }
      var brightness: Float = 0
      let readResult = getBrightness(displayID, &brightness)
      guard readResult == 0 else {
        return .failed("The built-in display brightness could not be read (\(readResult))")
      }
      if savedBrightness == nil {
        savedBrightness = brightness
      }
      let writeResult = setBrightness(displayID, 0)
      guard writeResult == 0 else {
        return .failed("The built-in display backlight could not be turned off (\(writeResult))")
      }
      return .applied
    }

    guard let brightness = savedBrightness else { return .applied }
    for attempt in 0..<20 {
      if let displayID = builtinDisplayID() {
        let writeResult = setBrightness(displayID, brightness)
        if writeResult == 0 {
          savedBrightness = nil
          return .applied
        }
        if attempt == 19 {
          return .failed("The built-in display brightness could not be restored (\(writeResult))")
        }
      } else if attempt == 19 {
        return .failed("The built-in display did not return after the lid opened")
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return .failed("The built-in display brightness could not be restored")
  }

  // MARK: Private

  private typealias GetBrightness = @convention(c) (
    CGDirectDisplayID,
    UnsafeMutablePointer<Float>,
  ) -> Int32
  private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

  private static let savedBrightnessKey = "closedLidPreviousBuiltinBrightness"

  private let framework: UnsafeMutableRawPointer?
  private let getBrightness: GetBrightness?
  private let setBrightness: SetBrightness?

  private var savedBrightness: Float? {
    get {
      (UserDefaults.standard.object(forKey: Self.savedBrightnessKey) as? NSNumber)?.floatValue
    }
    set {
      if let newValue {
        UserDefaults.standard.set(newValue, forKey: Self.savedBrightnessKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Self.savedBrightnessKey)
      }
    }
  }

  private func builtinDisplayID() -> CGDirectDisplayID? {
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    guard
      CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success
    else { return nil }
    return displays.prefix(Int(displayCount)).first(where: { CGDisplayIsBuiltin($0) != 0 })
  }

}

// MARK: - IdleSleepAssertion

private final class IdleSleepAssertion: @unchecked Sendable {

  // MARK: Internal

  func acquire() -> Bool {
    guard assertionID == nil else { return true }
    var newID = IOPMAssertionID(0)
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "Amado Caffeinate" as CFString,
      &newID,
    )
    guard result == kIOReturnSuccess else { return false }
    assertionID = newID
    return true
  }

  func release() {
    guard let assertionID else { return }
    IOPMAssertionRelease(assertionID)
    self.assertionID = nil
  }

  // MARK: Private

  private var assertionID: IOPMAssertionID?

}

// MARK: - LidMonitor

/// Event-driven `IOPMrootDomain` observer. It only publishes actual state
/// transitions, so restoring a configured app while the lid is already closed
/// does not manufacture a fresh lock event.
private final class LidMonitor: @unchecked Sendable {

  // MARK: Lifecycle

  private init() {
    var continuation: AsyncStream<Bool>.Continuation!
    changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    self.continuation = continuation

    rootDomain = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("IOPMrootDomain"),
    )
    guard rootDomain != 0 else { return }
    previousClosed = Self.readClosed(from: rootDomain) ?? false

    guard let notificationPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
    self.notificationPort = notificationPort
    IONotificationPortSetDispatchQueue(notificationPort, queue)
    let result = IOServiceAddInterestNotification(
      notificationPort,
      rootDomain,
      kIOGeneralInterest,
      Self.interestCallback,
      Unmanaged.passUnretained(self).toOpaque(),
      &notification,
    )
    if result != kIOReturnSuccess {
      logger.error("lid notification registration failed: \(result, privacy: .public)")
    }
  }

  deinit {
    if notification != 0 { IOObjectRelease(notification) }
    if rootDomain != 0 { IOObjectRelease(rootDomain) }
    if let notificationPort { IONotificationPortDestroy(notificationPort) }
    continuation.finish()
  }

  // MARK: Internal

  static let shared = LidMonitor()

  static var isSupported: Bool {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("IOPMrootDomain"),
    )
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    return readClosed(from: service) != nil
  }

  let changes: AsyncStream<Bool>

  // MARK: Private

  private static let interestCallback: IOServiceInterestCallback = { context, service, _, _ in
    guard let context else { return }
    let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleInterest(service: service)
  }

  private let continuation: AsyncStream<Bool>.Continuation
  private let queue = DispatchQueue(label: "dev.PangMo5.Amado.lid-monitor")
  private var notification: io_object_t = 0
  private var notificationPort: IONotificationPortRef?
  private var previousClosed = false
  private var rootDomain: io_service_t = 0

  private static func readClosed(from service: io_service_t) -> Bool? {
    guard
      let property = IORegistryEntryCreateCFProperty(
        service,
        "AppleClamshellState" as CFString,
        kCFAllocatorDefault,
        0,
      )?.takeRetainedValue()
    else { return nil }
    return (property as? Bool) ?? (property as? NSNumber)?.boolValue
  }

  private func handleInterest(service: io_service_t) {
    guard let closed = Self.readClosed(from: service), closed != previousClosed else { return }
    previousClosed = closed
    continuation.yield(closed)
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "ClosedLidControl")
