import Foundation

// MARK: - LockActionFeedback

/// The most recent user-visible result of a Widget or Control Center lock
/// action. The app extension persists one value in the shared App Group so each
/// system surface can redraw after its App Intent finishes.
public struct LockActionFeedback: Codable, Equatable, Identifiable, Sendable {

  // MARK: Lifecycle

  public init(
    id: UUID = UUID(),
    surface: Surface,
    macID: UUID?,
    macName: String,
    result: Result,
    createdAt: Date = Date(),
  ) {
    self.id = id
    self.surface = surface
    self.macID = macID
    self.macName = macName
    self.result = result
    self.createdAt = createdAt
  }

  // MARK: Public

  public enum Surface: String, Codable, Equatable, Sendable {
    case control
    case widget
  }

  public enum Result: String, Codable, Equatable, Sendable {
    case locked
    case unlocked
    case alreadyLocked
    case confirmationUnavailable
    case statusUnavailable
    case failed
    case noPairedMac
  }

  /// Feedback remains useful long enough to notice on the Home Screen, then
  /// the widget returns to its normal "Tap to lock" affordance.
  public static let displayDuration: TimeInterval = 5 * 60

  public let id: UUID
  public let surface: Surface
  public let macID: UUID?
  public let macName: String
  public let result: Result
  public let createdAt: Date

  public var statusText: String {
    switch result {
    case .locked: "Locked \(macName)"
    case .unlocked: "\(macName) is unlocked"
    case .alreadyLocked: "\(macName) is already locked"
    case .confirmationUnavailable: "Lock requested; couldn't confirm"
    case .statusUnavailable: "Couldn't refresh \(macName) status"
    case .failed: "Couldn't lock \(macName)"
    case .noPairedMac: "Pair a Mac first"
    }
  }

  public var widgetHint: String {
    switch result {
    case .locked: "Locked"
    case .unlocked: "Unlocked"
    case .alreadyLocked: "Already locked"
    case .confirmationUnavailable: "Sent — couldn't confirm"
    case .statusUnavailable: "Status unavailable"
    case .failed: "Failed — tap to retry"
    case .noPairedMac: "Pair a Mac first"
    }
  }

  public var systemImage: String {
    switch result {
    case .locked: "checkmark.circle.fill"
    case .unlocked: "lock.open.fill"
    case .alreadyLocked: "lock.fill"
    case .confirmationUnavailable: "questionmark.circle.fill"
    case .statusUnavailable: "arrow.clockwise.circle.fill"
    case .failed,
         .noPairedMac: "exclamationmark.triangle.fill"
    }
  }

  public var isFailure: Bool {
    result == .failed || result == .statusUnavailable || result == .noPairedMac
  }

  public static func responding(
    to outcome: LockCommandResponse.Outcome,
    surface: Surface,
    mac: PairedMac,
    id: UUID = UUID(),
    now: Date = Date(),
  ) -> Self {
    let result: Result =
      switch outcome {
      case .locked: .locked
      case .alreadyLocked: .alreadyLocked
      case .lockRequested: .confirmationUnavailable
      case .helloAccepted,
           .unlocked: .failed
      }
    return Self(
      id: id,
      surface: surface,
      macID: mac.id,
      macName: mac.displayName,
      result: result,
      createdAt: now,
    )
  }

  public static func reflectingStatus(
    _ outcome: LockCommandResponse.Outcome,
    surface: Surface,
    mac: PairedMac,
    id: UUID = UUID(),
    now: Date = Date(),
  ) -> Self {
    let result: Result =
      switch outcome {
      case .locked,
           .alreadyLocked: .locked
      case .unlocked: .unlocked
      case .helloAccepted,
           .lockRequested: .statusUnavailable
      }
    return Self(
      id: id,
      surface: surface,
      macID: mac.id,
      macName: mac.displayName,
      result: result,
      createdAt: now,
    )
  }

  public func isRecent(
    at now: Date = Date(),
    maxAge: TimeInterval = Self.displayDuration,
  ) -> Bool {
    let age = now.timeIntervalSince(createdAt)
    return age >= 0 && age <= maxAge
  }

}

// MARK: - LockActionFeedbackStore

public enum LockActionFeedbackStore {
  public static var fileURL: URL {
    let directory = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: AmadoService.appGroup)
      ?? URL.documentsDirectory
    return directory.appending(path: "lock-action-feedback.json")
  }

  public static func load(
    surface: LockActionFeedback.Surface,
    macID: UUID?,
    now: Date = Date(),
  ) -> LockActionFeedback? {
    guard
      let data = try? Data(contentsOf: fileURL),
      let feedback = try? JSONDecoder().decode(LockActionFeedback.self, from: data),
      feedback.surface == surface,
      feedback.macID == macID,
      feedback.isRecent(at: now)
    else { return nil }
    return feedback
  }

  public static func save(_ feedback: LockActionFeedback) {
    guard let data = try? JSONEncoder().encode(feedback) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
