import Dependencies
import DependenciesMacros
import Sparkle

// MARK: - UpdaterClient

/// Owns Sparkle's updater controller so background checks start with the Mac
/// agent and reducer/view code can trigger a user-initiated check.
@DependencyClient
struct UpdaterClient: Sendable {
  /// Resolving the live client creates and starts Sparkle's controller.
  var start: @Sendable () -> Void
  var checkForUpdates: @Sendable () -> Void
}

// MARK: DependencyKey

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = MainActor.assumeIsolated {
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil,
    )
    let updater = controller.updater
    return UpdaterClient(
      start: { },
      checkForUpdates: {
        Task { @MainActor in updater.checkForUpdates() }
      },
    )
  }

  static let testValue = UpdaterClient(start: { }, checkForUpdates: { })
  static let previewValue = testValue
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
