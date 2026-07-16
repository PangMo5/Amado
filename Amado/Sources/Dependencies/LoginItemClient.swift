import Dependencies
import DependenciesMacros
import OSLog
import ServiceManagement

// MARK: - LoginItemClient

/// Registers/unregisters Amado as a macOS login item via `SMAppService.mainApp`
/// so the agent starts automatically at login.
@DependencyClient
struct LoginItemClient: Sendable {
  /// Register (true) or unregister (false) the app as a login item.
  var setEnabled: @Sendable (Bool) -> Void
  /// Whether the app is currently registered as a login item.
  var isEnabled: @Sendable () -> Bool = { false }
}

// MARK: DependencyKey

extension LoginItemClient: DependencyKey {
  static let liveValue = LoginItemClient(
    setEnabled: { enabled in
      let service = SMAppService.mainApp
      do {
        switch (enabled, service.status) {
        case (true, let status) where status != .enabled:
          try service.register()
        case (false, .enabled):
          try service.unregister()
        default:
          break
        }
      } catch {
        logger.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
      }
    },
    isEnabled: { SMAppService.mainApp.status == .enabled },
  )

  static let testValue = LoginItemClient(setEnabled: { _ in }, isEnabled: { false })
  static let previewValue = testValue
}

extension DependencyValues {
  var loginItem: LoginItemClient {
    get { self[LoginItemClient.self] }
    set { self[LoginItemClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "LoginItem")
