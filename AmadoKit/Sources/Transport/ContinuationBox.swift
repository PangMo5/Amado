import Foundation

/// Guards a `CheckedContinuation` so exactly one of several callbacks resumes
/// it. A lock is the right tool: the callbacks (Network.framework state/result)
/// are synchronous and cross queue threads, and a continuation must be resumed
/// exactly once.
final class ContinuationBox<T: Sendable>: @unchecked Sendable {

  // MARK: Lifecycle

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = continuation
  }

  // MARK: Internal

  func resume(returning value: T) {
    lock.lock()
    defer { lock.unlock() }
    continuation?.resume(returning: value)
    continuation = nil
  }

  func resume(throwing error: Error) {
    lock.lock()
    defer { lock.unlock() }
    continuation?.resume(throwing: error)
    continuation = nil
  }

  // MARK: Private

  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?

}
