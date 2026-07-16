import Foundation

// MARK: - RemoteLockSender

/// Sends a signed command to a Mac's tunnel over HTTPS. The tunnel (Cloudflare
/// Tunnel / Tailscale Funnel / ngrok / self-host) terminates TLS and forwards to
/// the agent's local HTTP server, which verifies the HMAC and locks. A `200`
/// means the agent accepted the command; the body is never trusted (the HMAC in
/// the request is the only authority), so nothing here parses it.
public enum RemoteLockSender {
  public static func send(_ command: LockCommand, to baseURL: URL, secret: PairingSecret) async throws {
    let path = command.action == .hello ? AmadoService.helloPath : AmadoService.lockPath
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try LockCodec.encode(command, secret: secret)
    request.timeoutInterval = 10

    let response: URLResponse
    do {
      (_, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
      // Turn the raw NSURLError (e.g. "hostname could not be found") into an
      // actionable message: the tunnel is down / the stored host is stale.
      switch error.code {
      case .notConnectedToInternet,
           .networkConnectionLost:
        throw LockSenderError.offline
      default:
        throw LockSenderError.remoteUnreachable(host: baseURL.host ?? "the Mac")
      }
    }
    guard let http = response as? HTTPURLResponse else {
      throw LockSenderError.remoteUnreachable(host: baseURL.host ?? "the Mac")
    }
    guard http.statusCode == 200 else { throw LockSenderError.remoteRejected(status: http.statusCode) }
  }

  /// Connectivity probe: GET the agent's `/health` and confirm 200. Used by the
  /// Mac's "Test connection" button to check its own tunnel end-to-end.
  public static func probe(baseURL: URL) async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent(AmadoService.healthPath))
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw LockSenderError.notReachable }
    guard http.statusCode == 200 else { throw LockSenderError.remoteRejected(status: http.statusCode) }
  }
}
