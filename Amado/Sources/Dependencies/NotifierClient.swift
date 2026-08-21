// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import UserNotifications

// MARK: - NotifierClient

/// System notifications for failures the user has to act on.
///
/// The menu bar already carries every issue, so this only exists for the cases
/// where waiting until someone happens to open the menu is too late. One
/// notification per issue kind, replaced rather than stacked, and withdrawn as
/// soon as the issue clears.
@DependencyClient
struct NotifierClient: Sendable {
  var post: @Sendable (_ id: String, _ title: String, _ body: String) async -> Void
  var withdraw: @Sendable (_ id: String) async -> Void
}

// MARK: DependencyKey

extension NotifierClient: DependencyKey {
  static let liveValue = NotifierClient(
    post: { id, title, body in
      // Authorization is requested here rather than at launch so a user who
      // never hits a failure never sees the prompt.
      guard await isAuthorized() else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
      do {
        try await UNUserNotificationCenter.current().add(request)
      } catch {
        logger.error("could not post \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    },
    withdraw: { id in
      let center = UNUserNotificationCenter.current()
      center.removeDeliveredNotifications(withIdentifiers: [id])
      center.removePendingNotificationRequests(withIdentifiers: [id])
    },
  )

  static let testValue = NotifierClient(post: { _, _, _ in }, withdraw: { _ in })
  static let previewValue = testValue
}

extension DependencyValues {
  var notifier: NotifierClient {
    get { self[NotifierClient.self] }
    set { self[NotifierClient.self] = newValue }
  }
}

private func isAuthorized() async -> Bool {
  let center = UNUserNotificationCenter.current()
  switch await center.notificationSettings().authorizationStatus {
  case .authorized,
       .provisional:
    return true

  case .notDetermined:
    return (try? await center.requestAuthorization(options: [.alert])) ?? false

  // Denied, and anything a future macOS adds: respect it and stay quiet. The
  // menu bar still shows the issue.
  default:
    return false
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Amado", category: "Notifier")
