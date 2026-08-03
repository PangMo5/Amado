import Foundation

// MARK: - IncomingLockRequest

/// One authenticated transport request plus its one-shot response channel.
///
/// The listeners own transport details; the reducer owns replay protection,
/// state inspection, and command effects. This channel lets both sides keep
/// those responsibilities without returning an optimistic transport-only ACK.
struct IncomingLockRequest: Sendable {
  let data: Data
  let responseChannel: LockResponseChannel

  func respond(with data: Data) {
    responseChannel.respond(with: data)
  }
}

// MARK: - LockResponseChannel

/// A one-shot response channel with a bounded wait.
///
/// The reducer answers at most once and the transport waits at most `timeout`;
/// whichever comes first settles the channel and resumes the single awaiting
/// caller. A lock-guarded continuation — the same shape as `ContinuationBox`
/// on the client side — expresses that directly, so there is no child task
/// racing a timer and no structured-concurrency teardown in the response path.
final class LockResponseChannel: @unchecked Sendable {

  // MARK: Internal

  /// Deliver the reducer's answer. Calls after the channel settles are
  /// ignored: the wait has already expired and nobody is listening.
  func respond(with data: Data) {
    settle(with: data)?.resume(returning: data)
  }

  /// Wait for the reducer's answer, giving up after `timeout` so a silent
  /// reducer cannot pin the connection open. `nil` means "no answer".
  func firstResponse(timeout: Duration = .seconds(3)) async -> Data? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
      lock.lock()
      // Already settled: hand over the buffered answer, if the reducer beat us
      // here. A second caller gets nothing — the channel is one-shot.
      guard !isSettled, waiter == nil else {
        let answer = pending
        pending = nil
        lock.unlock()
        continuation.resume(returning: answer)
        return
      }
      waiter = continuation
      lock.unlock()
      Self.timeouts.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [self] in
        expire()
      }
    }
  }

  // MARK: Private

  private static let timeouts = DispatchQueue(label: "dev.PangMo5.Amado.response-timeout")

  private let lock = NSLock()
  private var waiter: CheckedContinuation<Data?, Never>?
  /// An answer that arrived before anyone awaited it.
  private var pending: Data?
  private var isSettled = false

  private func expire() {
    settle(with: nil)?.resume(returning: nil)
  }

  /// Settles the channel exactly once and returns the continuation to resume
  /// outside the lock, or `nil` when there is nothing to resume.
  private func settle(with data: Data?) -> CheckedContinuation<Data?, Never>? {
    lock.lock()
    defer { lock.unlock() }
    guard !isSettled else { return nil }
    isSettled = true
    guard let waiter else {
      pending = data
      return nil
    }
    self.waiter = nil
    return waiter
  }

}

extension Duration {
  fileprivate var dispatchInterval: DispatchTimeInterval {
    let (seconds, attoseconds) = components
    return .nanoseconds(Int(clamping: seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
  }
}
