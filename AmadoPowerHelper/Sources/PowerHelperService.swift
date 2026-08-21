import Foundation

// MARK: - RootPowerController

/// Owns the root-side leases. When the app's XPC connection disappears, its
/// lease is removed and normal sleep is restored immediately.
private actor RootPowerController {

  // MARK: Lifecycle

  init() {
    // A daemon restart is a fail-safe boundary: never inherit a stale global
    // sleep override from a crashed or upgraded helper.
    _ = Self.applyDisableSleep(false)
  }

  // MARK: Internal

  func setEnabled(_ enabled: Bool, leaseID: UUID) -> Bool {
    var nextLeases = leases
    if enabled {
      nextLeases.insert(leaseID)
    } else {
      nextLeases.remove(leaseID)
    }

    let wasEnabled = !leases.isEmpty
    let willBeEnabled = !nextLeases.isEmpty
    // An explicit Off with no recorded lease is a repair request after a
    // helper restart. Re-apply normal sleep instead of treating it as a no-op.
    if !enabled, !willBeEnabled {
      guard Self.applyDisableSleep(false) else { return false }
      leases = nextLeases
      return true
    }
    guard wasEnabled != willBeEnabled else {
      leases = nextLeases
      return true
    }
    guard Self.applyDisableSleep(willBeEnabled) else { return false }
    leases = nextLeases
    return true
  }

  func invalidate(leaseID: UUID) {
    guard leases.contains(leaseID) else { return }
    var nextLeases = leases
    nextLeases.remove(leaseID)
    leases = nextLeases
    if nextLeases.isEmpty {
      _ = Self.applyDisableSleep(false)
    }
  }

  func shutDown() {
    leases.removeAll()
    _ = Self.applyDisableSleep(false)
  }

  // MARK: Private

  private var leases = Set<UUID>()

  private static func applyDisableSleep(_ enabled: Bool) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "disablesleep", enabled ? "1" : "0"]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

}

// MARK: - PowerHelperService

private final class PowerHelperService: NSObject, PowerHelperProtocol, @unchecked Sendable {

  // MARK: Lifecycle

  init(controller: RootPowerController) {
    self.controller = controller
  }

  // MARK: Internal

  func setClosedLidMode(
    _ enabled: Bool,
    withReply reply: @escaping @Sendable (Bool) -> Void,
  ) {
    Task {
      reply(await controller.setEnabled(enabled, leaseID: leaseID))
    }
  }

  func invalidate() {
    Task { await controller.invalidate(leaseID: leaseID) }
  }

  // MARK: Private

  private let controller: RootPowerController
  private let leaseID = UUID()

}

// MARK: - PowerHelperListenerDelegate

final class PowerHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

  // MARK: Internal

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection,
  ) -> Bool {
    guard
      let requirement = PowerHelperCodeSigning.sameTeamRequirement(
        identifiers: PowerHelperConstants.appIdentifiers
      )
    else { return false }

    connection.setCodeSigningRequirement(requirement)
    let service = PowerHelperService(controller: controller)
    connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
    connection.exportedObject = service
    connection.invalidationHandler = { service.invalidate() }
    connection.interruptionHandler = { service.invalidate() }
    connection.resume()
    return true
  }

  func shutDown() async {
    await controller.shutDown()
  }

  // MARK: Private

  private let controller = RootPowerController()

}
