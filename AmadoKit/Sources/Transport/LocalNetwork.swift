import Foundation
@preconcurrency import Network

// MARK: - LocalNetwork

/// Best-effort check for a usable local network (Wi-Fi / wired). When there's
/// none — e.g. on cellular — the dispatcher fails fast instead of waiting out
/// the Bonjour browse timeout on a Mac it can't reach anyway.
enum LocalNetwork {
  static func isAvailable() async -> Bool {
    let probe = PathProbe()
    return await withCheckedContinuation { continuation in
      probe.attach(continuation)
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { path in
        let local = path.status == .satisfied
          && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
        monitor.cancel()
        probe.finish(local)
      }
      monitor.start(queue: queue)
      // If the path never reports, don't hang — assume local so LAN is tried.
      queue.asyncAfter(deadline: .now() + 1) { probe.finish(true) }
    }
  }

  private static let queue = DispatchQueue(label: "dev.PangMo5.Amado.path")
}

// MARK: - PathProbe

/// Resumes the probe's continuation exactly once (path update or timeout).
private final class PathProbe: @unchecked Sendable {

  // MARK: Internal

  func attach(_ continuation: CheckedContinuation<Bool, Never>) {
    lock.lock()
    defer { lock.unlock() }
    self.continuation = continuation
  }

  func finish(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    continuation?.resume(returning: value)
    continuation = nil
  }

  // MARK: Private

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?

}
