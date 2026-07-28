import Foundation
import Testing

@testable import AmadoKit

struct LockActionFeedbackTests {
  @Test(
    arguments: [
      (LockCommandResponse.Outcome.locked, LockActionFeedback.Result.locked),
      (.alreadyLocked, .alreadyLocked),
      (.lockRequested, .confirmationUnavailable),
      (.helloAccepted, .failed),
      (.notPaired, .noPairedMac),
      (.unpaired, .failed),
      (.unlocked, .failed),
    ]
  )
  func `maps command outcomes to visible feedback`(
    outcome: LockCommandResponse.Outcome,
    expected: LockActionFeedback.Result,
  ) {
    let mac = PairedMac(id: UUID(), name: "MacBook Pro", secretBase64: "")

    let feedback = LockActionFeedback.responding(
      to: outcome,
      surface: .widget,
      mac: mac,
    )

    #expect(feedback.result == expected)
    #expect(feedback.macID == mac.id)
    #expect(feedback.macName == mac.displayName)
  }

  @Test(
    arguments: [
      (LockCommandResponse.Outcome.locked, LockActionFeedback.Result.locked),
      (.alreadyLocked, .locked),
      (.unlocked, .unlocked),
      (.helloAccepted, .statusUnavailable),
      (.notPaired, .noPairedMac),
      (.unpaired, .statusUnavailable),
      (.lockRequested, .statusUnavailable),
    ]
  )
  func `maps status outcomes to visible feedback`(
    outcome: LockCommandResponse.Outcome,
    expected: LockActionFeedback.Result,
  ) {
    let mac = PairedMac(id: UUID(), name: "MacBook Pro", secretBase64: "")

    let feedback = LockActionFeedback.reflectingStatus(
      outcome,
      surface: .widget,
      mac: mac,
    )

    #expect(feedback.result == expected)
    #expect(feedback.macID == mac.id)
    #expect(feedback.macName == mac.displayName)
  }

  @Test
  func `expires transient feedback after its display window`() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let feedback = LockActionFeedback(
      surface: .control,
      macID: UUID(),
      macName: "MacBook Pro",
      result: .locked,
      createdAt: now,
    )

    #expect(feedback.isRecent(at: now.addingTimeInterval(LockActionFeedback.displayDuration)))
    #expect(!feedback.isRecent(at: now.addingTimeInterval(LockActionFeedback.displayDuration + 1)))
    #expect(!feedback.isRecent(at: now.addingTimeInterval(-1)))
  }
}
