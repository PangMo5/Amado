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

/// A single-producer/single-consumer response stream with a bounded wait.
final class LockResponseChannel: Sendable {

  // MARK: Lifecycle

  init() {
    var continuation: AsyncStream<Data>.Continuation!
    responses = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    self.continuation = continuation
  }

  // MARK: Internal

  func respond(with data: Data) {
    continuation.yield(data)
    continuation.finish()
  }

  func firstResponse(timeout: Duration = .seconds(3)) async -> Data? {
    await withTaskGroup(of: Data?.self) { group in
      group.addTask {
        for await response in self.responses {
          return response
        }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let response = await group.next() ?? nil
      group.cancelAll()
      return response
    }
  }

  // MARK: Private

  private let responses: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation

}
