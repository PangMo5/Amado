import Foundation

/// Shared constants for the Amado wire protocol.
public enum AmadoService {
  /// Bonjour service type the Mac agent advertises and clients browse for on
  /// the local network. Declared in each app's `NSBonjourServices` Info.plist.
  public static let serviceType = "_amado._tcp"

  /// TCP port the Mac agent listens on for LAN (raw-TCP) commands. Bonjour
  /// carries it to clients, so a fixed value isn't required, but pinning one
  /// keeps things predictable.
  public static let defaultPort = 51_520

  /// Local port the agent's HTTP server listens on for remote commands. A
  /// user-run tunnel (Cloudflare/Tailscale Funnel/ngrok) forwards its public
  /// host to `127.0.0.1:localHTTPPort`; clients never hit this port directly.
  public static let localHTTPPort = 51_521

  /// HTTP paths the agent's server exposes (also the remote client's routes).
  public static let lockPath = "lock"
  public static let helloPath = "hello"
  public static let statusPath = "status"
  public static let unpairPath = "unpair"
  /// Unauthenticated connectivity probe: returns 200 so a user can confirm their
  /// tunnel actually reaches the running agent. Never locks.
  public static let healthPath = "health"

  /// Wire-protocol version. Bumped whenever the envelope layout changes so an
  /// old client talking to a new agent fails loudly instead of misparsing.
  public static let protocolVersion = 1

  /// App Group shared by the iOS app and its widget/control extensions, so a
  /// widget can read the paired Macs the app stored. (macOS doesn't use it.)
  public static let appGroup = "group.dev.PangMo5.Amado"

  /// Stable identifiers used to reload the Home Screen widget and Control
  /// Center control after an App Intent writes user-visible feedback.
  public static let lockWidgetKind = "dev.PangMo5.Amado.LockWidget"
  public static let lockControlKind = "dev.PangMo5.Amado.LockControl"
}
