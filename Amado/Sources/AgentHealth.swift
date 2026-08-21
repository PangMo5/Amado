import Foundation

// MARK: - AgentIssueRecovery

/// What the menu can offer to do about an issue.
enum AgentIssueRecovery: Equatable, Sendable {
  /// Ask the agent to bring the subsystem back up now, ahead of its backoff.
  case retry
  /// Send the user to the System Settings pane that owns the problem.
  case openSettings(URL)
  /// Open Login Items & Extensions, where macOS approves the bundled root
  /// helper used by closed-lid mode.
  case openLoginItems

  // MARK: Internal

  var title: String {
    switch self {
    case .retry: "Try Again"
    case .openSettings: "Open Settings"
    case .openLoginItems: "Open Settings"
    }
  }
}

// MARK: - AgentIssue

/// One thing that is currently wrong with the agent.
///
/// The agent is a menu bar app with no window, so a failure that only reaches
/// the log is a failure the user never learns about. Every subsystem that can
/// stop working reports itself here instead, and the menu bar renders whatever
/// is worst. An issue is raised when a subsystem breaks and cleared when it
/// recovers, so the list always describes the present, not a history.
struct AgentIssue: Equatable, Sendable, Identifiable {

  // MARK: Lifecycle

  init(kind: Kind, detail: String, recovery: AgentIssueRecovery? = nil) {
    self.kind = kind
    self.detail = detail
    self.recovery = recovery ?? kind.defaultRecovery
  }

  // MARK: Internal

  enum Kind: String, Equatable, Sendable, CaseIterable {
    /// The LAN listener is not accepting commands, so nearby devices cannot
    /// reach this Mac at all. Nothing else matters while this is broken.
    case lanListener
    /// `SACLockScreenImmediate` could not be resolved, so lock commands
    /// arrive but cannot do anything.
    case screenLock
    /// The pairing secret could not be written to the Keychain, so the
    /// current pairings will not survive a restart.
    case pairingSecret
    /// Bluetooth is off or not permitted, so proximity auto-lock is idle.
    case bluetooth
    /// The user-approved root helper is not active, so the configured
    /// closed-lid sleep override cannot be applied.
    case closedLidPower
    /// The built-in display backlight could not be changed without requesting
    /// system display sleep and violating the selected lock policy.
    case closedLidDisplay
    /// The tunnel-facing HTTP server stopped; the LAN path still works.
    case remoteListener
    /// Launch at login could not be registered or unregistered.
    case loginItem
    /// The config directory is not writable, so settings will not persist.
    case config

    // MARK: Internal

    /// Worst first. The menu bar icon and banner show the most severe issue,
    /// since one line of menu real estate cannot explain several at once.
    var severity: Int {
      switch self {
      case .lanListener: 0
      case .screenLock: 1
      case .pairingSecret: 2
      case .closedLidPower: 3
      case .closedLidDisplay: 4
      case .bluetooth: 5
      case .remoteListener: 6
      case .loginItem: 7
      case .config: 8
      }
    }

    var title: String {
      switch self {
      case .lanListener: "Your devices can't reach this Mac"
      case .screenLock: "Amado can't lock this Mac"
      case .pairingSecret: "Pairing may not survive a restart"
      case .closedLidPower: "Caffeinate isn't active"
      case .closedLidDisplay: "Amado can't turn off the built-in display"
      case .bluetooth: "Auto-lock is waiting on Bluetooth"
      case .remoteListener: "Remote access is offline"
      case .loginItem: "Launch at login didn't change"
      case .config: "Settings aren't being saved"
      }
    }

    /// Whether the user has to do something for this to clear. Only these are
    /// worth a notification; the rest wait in the menu.
    var interrupts: Bool {
      switch self {
      case .bluetooth,
           .closedLidDisplay,
           .closedLidPower,
           .lanListener,
           .pairingSecret,
           .screenLock: true
      case .config,
           .loginItem,
           .remoteListener: false
      }
    }

    // MARK: Fileprivate

    fileprivate var defaultRecovery: AgentIssueRecovery? {
      switch self {
      case .lanListener,
           .remoteListener: .retry
      case .bluetooth,
           .closedLidDisplay,
           .closedLidPower,
           .config,
           .loginItem,
           .pairingSecret,
           .screenLock: nil
      }
    }
  }

  let kind: Kind
  /// The concrete cause, in the words of whatever failed.
  let detail: String
  /// Set per issue rather than per kind so one kind can point at different
  /// places (Bluetooth being off and Bluetooth being denied need different
  /// System Settings panes).
  let recovery: AgentIssueRecovery?

  var id: Kind {
    kind
  }

  var title: String {
    kind.title
  }

}

// MARK: - AgentHealth

/// What the menu bar renders. Derived from the issue list plus the listener
/// and pause state, so one place decides which of several true things the
/// icon should say.
enum AgentHealth: Equatable, Sendable {
  case starting
  case listening
  case closedLidAwake(
    policy: ClosedLidMode.AwakePolicy,
    autoLockPause: AutoLockPause?,
  )
  case paused(AutoLockPause)
  case impaired(AgentIssue)
}

// MARK: - MenuBarIndicatorState

/// Independent visual facts rendered by the menu bar icon. Each property owns
/// exactly one layer so one feature never changes another feature's symbol.
struct MenuBarIndicatorState: Equatable, Hashable, Sendable {
  let isAutoLockEnabled: Bool
  let closedLidPolicy: ClosedLidMode.AwakePolicy?
  let isAutoLockPaused: Bool
  let needsAttention: Bool
}

// MARK: - SystemSettings

/// Deep links into the System Settings panes Amado sends people to.
enum SystemSettings {
  static let bluetooth = URL(string: "x-apple.systempreferences:com.apple.Bluetooth")
  static let bluetoothPrivacy = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
  )
}
