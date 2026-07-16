import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - ScreenLockerClient

/// Locks the Mac by dropping it to the login window immediately.
@DependencyClient
struct ScreenLockerClient: Sendable {
  var lock: @Sendable () -> Void
}

// MARK: DependencyKey

extension ScreenLockerClient: DependencyKey {
  static let liveValue = ScreenLockerClient(lock: lockScreenImmediately)

  static let testValue = ScreenLockerClient(lock: { })
  static let previewValue = testValue
}

extension DependencyValues {
  var screenLocker: ScreenLockerClient {
    get { self[ScreenLockerClient.self] }
    set { self[ScreenLockerClient.self] = newValue }
  }
}

/// Calls `SACLockScreenImmediate()` from the private `login.framework`. This is
/// the same entry point Fast User Switching uses for "Lock Screen"; it shows
/// the login window right away regardless of the "require password" delay.
///
/// It is a private symbol resolved at runtime via `dlsym` (so there is no
/// link-time dependency and no App Store submission is implied). If the symbol
/// ever moves, the guard simply no-ops and logs — the agent stays alive.
private func lockScreenImmediately() {
  let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
  guard let handle = dlopen(path, RTLD_NOW) else {
    logger.error("login.framework not loadable — cannot lock")
    return
  }
  defer { dlclose(handle) }
  guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
    logger.error("SACLockScreenImmediate symbol missing — cannot lock")
    return
  }
  typealias LockFn = @convention(c) () -> Int32
  let lock = unsafeBitCast(symbol, to: LockFn.self)
  let result = lock()
  logger.log("SACLockScreenImmediate returned \(result)")
}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "ScreenLocker")
