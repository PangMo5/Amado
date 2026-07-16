import Foundation

// MARK: - AmadoLockDispatcher

/// The single entry point for sending a command to one Mac. Two transports,
/// tried in order:
///   1. **LAN** — browse Bonjour for the agent and deliver over raw TCP.
///      Instant, zero-config, works whenever the phone and Mac share a network.
///   2. **Remote** — HTTPS POST to the Mac's tunnel host (set at pairing), which
///      forwards to the agent's local HTTP server. Only available when the Mac
///      has remote access configured.
///
/// On the LAN it tries #1 and falls back to #2 if the Mac isn't found there but
/// has a tunnel; off the LAN it goes straight to #2. With neither reachable it
/// fails fast with a clear error rather than silently queuing. Used by the phone
/// reducer, the widget/control intent, and (via the phone relay) the watch, so
/// they all behave identically.
public enum AmadoLockDispatcher {
  public static func dispatch(_ command: LockCommand, to mac: PairedMac) async throws {
    guard let secret = mac.secret else { throw LockSenderError.notPaired }

    if await LocalNetwork.isAvailable() {
      do {
        try await LANLockSender().send(
          command,
          toMacNamed: mac.name.isEmpty ? nil : mac.name,
          secret: secret,
        )
        return
      } catch {
        // Not found on this network — try the tunnel if the Mac has one,
        // otherwise surface the LAN failure.
        guard let remoteURL = mac.remoteURL else { throw error }
        try await RemoteLockSender.send(command, to: remoteURL, secret: secret)
        return
      }
    }

    // No usable LAN (e.g. on cellular): the tunnel is the only way in.
    guard let remoteURL = mac.remoteURL else { throw LockSenderError.notReachable }
    try await RemoteLockSender.send(command, to: remoteURL, secret: secret)
  }
}
