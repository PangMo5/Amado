// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AmadoKit
import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

// MARK: - SettingsView

/// System-Settings-style window (sidebar of panes + grouped form), mirroring
/// the sibling Tatami project. Drives Launch at Login, pairing, and About off
/// the shared `AppFeature` store.
struct SettingsView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    NavigationSplitView {
      // `id: \.self` so the ForEach id type matches the optional selection type.
      List(Pane.allCases, id: \.self, selection: $pane) { pane in
        Label(pane.title, systemSymbol: pane.icon)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    } detail: {
      Form {
        switch pane ?? .general {
        case .general: generalPane
        case .proximity: ProximitySettingsPane(store: store)
        case .caffeinate: CaffeinateSettingsPane(store: store)
        case .remote: remotePane
        case .pairing: pairingPane
        case .about: AboutSection(store: store)
        }
      }
      .formStyle(.grouped)
      .navigationTitle((pane ?? .general).title)
    }
    .frame(minWidth: 640, minHeight: 460)
  }

  // MARK: Private

  private enum Pane: String, CaseIterable, Identifiable {
    case general
    case proximity
    case caffeinate
    case remote
    case pairing
    case about

    // MARK: Internal

    var id: String {
      rawValue
    }

    var title: String {
      switch self {
      case .general: "General"
      case .proximity: "Auto-lock"
      case .caffeinate: "Caffeinate"
      case .remote: "Remote access"
      case .pairing: "Pairing"
      case .about: "About"
      }
    }

    var icon: SFSymbol {
      switch self {
      case .general: .gearshape
      case .proximity: .figureWalk
      case .caffeinate: .cupAndSaucerFill
      case .remote: .network
      case .pairing: .qrcode
      case .about: .infoCircle
      }
    }
  }

  @State private var pane: Pane? = .general
  /// The pairing code is sensitive, so it stays hidden until explicitly revealed.
  @State private var secretRevealed = false

  private var payloadString: String {
    let identity = store.macIdentity
    return PairingPayload(
      name: identity?.name ?? "Mac",
      secret: store.pairingSecretBase64,
      remoteHost: store.config.remoteHost.isEmpty ? nil : store.config.remoteHost,
      deviceID: identity?.id,
      serviceName: identity?.serviceName,
    ).encoded()
  }

  private var statusLine: String {
    switch store.health {
    case .impaired(let issue):
      return issue.title

    case .paused(let pause):
      return autoLockPauseDescription(pause)

    case .closedLidAwake(let policy, let autoLockPause):
      let prefix = "Caffeinate active; \(policy.statusDescription)"
      guard let autoLockPause else { return prefix }
      return "\(prefix); \(autoLockPauseDescription(autoLockPause).lowercased())"

    case .listening:
      return "Listening"

    case .starting:
      return "Starting…"
    }
  }

  private var generalPane: some View {
    Group {
      MacIdentitySection(
        name: store.macIdentity?.name ?? "Mac",
        deviceID: store.config.macID,
      )
      AgentIssuesSection(store: store)
      Section {
        Toggle(
          "Launch at Login",
          isOn: Binding(
            get: { store.launchAtLogin },
            set: { store.send(.launchAtLoginToggled($0)) },
          ),
        )
        LabeledContent("Status", value: statusLine)
      }
      Section {
        Button("Lock this Mac now") { store.send(.lockNowTapped) }
      } footer: {
        Text("Locks immediately — mainly to test the agent.")
      }
    }
  }

  private var remotePane: some View {
    Group {
      Section {
        TextField(
          "amado.example.com",
          text: Binding(
            get: { store.config.remoteHost },
            set: { store.send(.remoteHostChanged($0)) },
          ),
        )
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
      } header: {
        Text("Tunnel host")
      } footer: {
        Text(
          "Public hostname of a tunnel you run on this Mac (Cloudflare Tunnel, "
            + "Tailscale Funnel, ngrok…) forwarding to 127.0.0.1:\(AmadoService.localHTTPPort). "
            + "Leave empty for LAN-only. See the configuration guide on the Amado website."
        )
      }
      Section {
        Button {
          store.send(.testRemoteTapped)
        } label: {
          if store.remoteTesting {
            ProgressView().controlSize(.small)
          } else {
            Text("Test connection")
          }
        }
        .disabled(store.config.remoteHost.isEmpty || store.remoteTesting)
        if !store.remoteTestMessage.isEmpty {
          Text(store.remoteTestMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Checks that your tunnel reaches this Mac’s agent.")
      }
    }
  }

  @ViewBuilder
  private var pairingPane: some View {
    if !store.pairedClients.isEmpty {
      Section {
        ForEach(store.pairedClients) { client in
          HStack {
            Image(systemSymbol: .iphone)
              .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
              Text(client.name)
              Text("Last seen \(client.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", role: .destructive) {
              store.send(.removePairedClient(client.id))
            }
          }
        }
      } header: {
        Text("Paired devices")
      } footer: {
        Text(
          "Removing a device also removes this Mac from that iPhone the next time it connects. "
            + "Scan the pairing code again to restore access."
        )
      }
    }

    if let device = store.justPairedWith {
      Section {
        Label("Paired with \(device)", systemSymbol: .checkmarkSealFill)
          .foregroundStyle(.green)
      }
    }
    if secretRevealed {
      Section {
        if !store.pairingSecretBase64.isEmpty, let image = PairingQR.image(for: payloadString) {
          HStack {
            Spacer()
            Image(decorative: image, scale: 1)
              .resizable()
              .interpolation(.none)
              .frame(width: 200, height: 200)
              .accessibilityLabel("Pairing QR code")
            Spacer()
          }
        }
        Text(store.pairingSecretBase64)
          .font(.footnote.monospaced())
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
      } header: {
        Text("Pair a device")
      } footer: {
        Text("Anyone who sees this can lock your Mac — keep it private.")
      }
      Section {
        Button("Copy pairing code") { copy(payloadString) }
          .disabled(store.pairingSecretBase64.isEmpty)
        Button("Hide") { secretRevealed = false }
        Button("Regenerate pairing secret…", role: .destructive) { store.send(.regenerateSecretTapped) }
      }
    } else {
      Section {
        Button("Reveal pairing code") { secretRevealed = true }
      } header: {
        Text("Pair a device")
      } footer: {
        Text("The pairing code lets any device lock this Mac, so it stays hidden until you reveal it.")
      }
    }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

  private func autoLockPauseDescription(_ pause: AutoLockPause) -> String {
    switch pause {
    case .until(let deadline):
      "Auto-lock paused until \(deadline.formatted(date: .abbreviated, time: .shortened))"
    case .whileCaffeinating:
      "Auto-lock paused while Caffeinate keeps the Mac unlocked"
    }
  }

}

// MARK: - CaffeinateSettingsPane

private struct CaffeinateSettingsPane: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    Group {
      Section {
        Picker(
          "When the lid closes",
          selection: Binding(
            get: { store.config.closedLidMode },
            set: { store.send(.closedLidModeChanged($0)) },
          ),
        ) {
          ForEach(ClosedLidMode.allCases, id: \.self) { mode in
            Text(mode.title)
              .tag(mode)
          }
        }
        .disabled(!store.powerHelperStatus.isReady)

        if store.config.closedLidMode.keepsAwake {
          Label(
            "Caffeinate disables normal lid-close sleep. Use this Mac only on a hard, stable, "
              + "well-ventilated surface—never in a bag, bedding, or enclosed space. You are "
              + "responsible for monitoring heat and battery.",
            systemSymbol: .exclamationmarkTriangleFill,
          )
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .combine)
        }

        if store.config.closedLidMode == .unlocked {
          Label(
            "Caffeinate does not lock the login session when the lid closes. Anyone with physical access—or access through remote-control software already enabled on this Mac—may be able to use the session and access its data.",
            systemSymbol: .exclamationmarkTriangleFill,
          )
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .combine)
        }
      } header: {
        Text("Behavior")
      }

      Section {
        LabeledContent(
          "Installation",
          value: helperStatusSummary,
        )
        LabeledContent(
          "Caffeinate status",
          value: statusSummary,
        )
        if
          store.config.closedLidMode.keepsAwake,
          !store.isApplyingClosedLidMode,
          !store.isRemovingPowerHelper,
          store.closedLidStatus != .active
        {
          Button("Try Again") { store.send(.closedLidRetryTapped) }
        }
        HStack {
          Button(store.powerHelperStatus.installButtonTitle) {
            store.send(.caffeinateInstallHelperTapped)
          }
          .disabled(!store.powerHelperStatus.canInstall || isHelperBusy)

          Button("Remove Power Helper…", role: .destructive) {
            store.send(.caffeinateRemoveHelperTapped)
          }
          .disabled(!store.powerHelperStatus.canRemove || isHelperBusy)
        }

        if store.powerHelperStatus == .requiresApproval {
          Button("Open Login Items & Extensions…") {
            store.send(.caffeinateHelperSettingsTapped)
          }
          Button("Check Again") {
            store.send(.caffeinateHelperStatusRefreshTapped)
          }
          .disabled(isHelperBusy)
        }
      } header: {
        Text("Power Helper")
      } footer: {
        Text(
          "Amado uses a narrowly scoped Power Helper to keep macOS running after the MacBook lid closes. "
            + "Install it explicitly before enabling Caffeinate; macOS may ask an administrator to approve "
            + "it in Login Items & Extensions. The helper restores normal sleep if Amado disconnects. "
            + "Removing it turns Caffeinate off."
        )
      }

      Section {
        Text(
          "Both awake policies turn off the built-in display: the lock policy uses display sleep, "
            + "while the unlocked policy turns off only the built-in backlight and restores its "
            + "previous brightness when the lid opens."
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("Display behavior")
      }
    }
  }

  // MARK: Private

  private var statusSummary: String {
    if store.isRemovingPowerHelper { return "Removing…" }
    if store.isApplyingClosedLidMode { return "Starting…" }
    return store.closedLidStatus.summary
  }

  private var helperStatusSummary: String {
    if store.isInstallingPowerHelper { return "Installing…" }
    if store.isRefreshingPowerHelper { return "Checking…" }
    if store.isRemovingPowerHelper { return "Removing…" }
    return store.powerHelperStatus.summary
  }

  private var isHelperBusy: Bool {
    store.isInstallingPowerHelper
      || store.isRefreshingPowerHelper
      || store.isRemovingPowerHelper
  }

}

// MARK: - AgentIssuesSection

/// Everything currently wrong with the agent. The menu bar only has room for
/// the worst one, so this is where the rest become visible. It disappears
/// entirely when the agent is healthy rather than showing a reassuring row
/// nobody needs to read.
private struct AgentIssuesSection: View {

  let store: StoreOf<AppFeature>

  var body: some View {
    if !store.issues.isEmpty {
      Section {
        ForEach(store.issues) { issue in
          LabeledContent {
            IssueRecoveryButton(issue: issue) {
              store.send(.issueRecoveryTapped(issue.kind))
            }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.title)
              Text(issue.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      } header: {
        Label("Needs attention", systemSymbol: .exclamationmarkTriangleFill)
          .foregroundStyle(.orange)
      }
    }
  }

}

// MARK: - IssueRecoveryButton

private struct IssueRecoveryButton: View {

  // MARK: Internal

  let issue: AgentIssue
  let onRetry: () -> Void

  var body: some View {
    switch issue.recovery {
    case .retry:
      Button("Try Again", action: onRetry)

    case .openSettings(let url):
      Button("Open Settings") { openURL(url) }

    case .openLoginItems:
      Button("Open Settings", action: onRetry)

    case nil:
      EmptyView()
    }
  }

  // MARK: Private

  @Environment(\.openURL) private var openURL

}

// MARK: - MacIdentitySection

private struct MacIdentitySection: View {
  let name: String
  let deviceID: String

  var body: some View {
    Section {
      LabeledContent("Name", value: name)
      LabeledContent("Device ID") {
        Text(deviceID)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
    } header: {
      Text("This Mac")
    } footer: {
      Text("The Mac name is supplied by macOS. The device ID keeps the pairing stable.")
    }
  }
}

// MARK: - AboutSection

private struct AboutSection: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    Section {
      HStack(spacing: 14) {
        if let icon = NSApplication.shared.applicationIconImage {
          Image(nsImage: icon)
            .resizable()
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Amado")
            .font(.title2.weight(.semibold))
          Text("One tap. Walk away. Close the lid.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }

    Section("About") {
      LabeledContent("Version", value: Self.appVersion)
      LabeledContent("Created by") {
        Link("PangMo5", destination: Self.creatorURL)
      }
      Link("GitHub", destination: Self.repositoryURL)
      Link("Release Notes", destination: Self.releaseNotesURL)
      Link("Privacy", destination: Self.privacyURL)
    }

    Section {
      Button("Check for Updates…") {
        store.send(.checkForUpdatesTapped)
      }
    } header: {
      Text("Software Update")
    } footer: {
      Text("Amado checks for signed updates with Sparkle.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("Legal") {
      LabeledContent("Copyright", value: "© 2026 PangMo5 and contributors")
      Text(
        "The Mac app is AGPL-3.0-only. The iPhone, Watch, Widget, and shared core sources are MPL-2.0. Select Licensing Notice for the exact boundary."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      ForEach(LegalDocument.allCases) { document in
        Button {
          presentedDocument = document
        } label: {
          Text(document.title)
        }
        .buttonStyle(.link)
      }
    }
    .sheet(item: $presentedDocument) { document in
      LegalDocumentView(document: document)
    }

    Section("Built with") {
      ForEach(Self.acknowledgements, id: \.name) { item in
        Link(item.name, destination: item.url)
      }
    }
  }

  // MARK: Private

  private static let creatorURL = URL(string: "https://github.com/PangMo5")!
  private static let repositoryURL = URL(string: "https://github.com/PangMo5/Amado")!
  private static let releaseNotesURL = URL(string: "https://pangmo5.dev/Amado/releases.html")!
  private static let privacyURL = URL(string: "https://pangmo5.dev/Amado/privacy.html")!

  private static let acknowledgements: [(name: String, url: URL)] = [
    (
      "The Composable Architecture",
      URL(string: "https://github.com/pointfreeco/swift-composable-architecture")!,
    ),
    ("swift-sharing", URL(string: "https://github.com/pointfreeco/swift-sharing")!),
    ("SFSafeSymbols", URL(string: "https://github.com/SFSafeSymbols/SFSafeSymbols")!),
    ("Sparkle", URL(string: "https://github.com/sparkle-project/Sparkle")!),
    ("Hummingbird", URL(string: "https://github.com/hummingbird-project/hummingbird")!),
    ("swift-toml", URL(string: "https://github.com/mattt/swift-toml")!),
  ]

  /// Marketing version + build number from the app bundle, e.g. "1.0.0 (42)".
  private static let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    return "\(short) (\(build))"
  }()

  @State private var presentedDocument: LegalDocument?

}

// MARK: - LegalDocument

/// Legal documents shipped in the app bundle and presented without relying on
/// an external editor or a network connection.
private enum LegalDocument: String, CaseIterable, Identifiable, Sendable {
  case macLicense
  case mobileLicense
  case licensingNotice

  // MARK: Internal

  var id: Self {
    self
  }

  var title: LocalizedStringResource {
    switch self {
    case .macLicense: "Mac License (AGPL-3.0-only)"
    case .mobileLicense: "iOS and Shared License (MPL-2.0)"
    case .licensingNotice: "Licensing Notice"
    }
  }

  func loadContents() async throws -> String {
    let resource = resource
    guard
      let url = Bundle.main.url(
        forResource: resource.name,
        withExtension: resource.extension,
      )
    else {
      throw CocoaError(.fileNoSuchFile)
    }

    return try await Task.detached(priority: .userInitiated) {
      try String(contentsOf: url, encoding: .utf8)
    }.value
  }

  // MARK: Private

  private var resource: (name: String, extension: String?) {
    switch self {
    case .macLicense: ("LICENSE", nil)
    case .mobileLicense: ("MPL-2.0", "txt")
    case .licensingNotice: ("NOTICE", "md")
    }
  }
}

// MARK: - LegalDocumentView

private struct LegalDocumentView: View {

  // MARK: Internal

  let document: LegalDocument

  var body: some View {
    NavigationStack {
      Group {
        if let contents {
          ScrollView {
            Text(contents)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
          }
        } else if let loadErrorMessage {
          ContentUnavailableView(
            "Unable to Open Document",
            systemImage: "doc.badge.exclamationmark",
            description: Text(loadErrorMessage),
          )
        } else {
          ProgressView("Loading document…")
        }
      }
      .navigationTitle(Text(document.title))
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 680, minHeight: 520)
    .task(id: document.id) {
      do {
        contents = try await document.loadContents()
      } catch {
        loadErrorMessage = error.localizedDescription
      }
    }
  }

  // MARK: Private

  @Environment(\.dismiss) private var dismiss
  @State private var contents: String?
  @State private var loadErrorMessage: String?

}

// MARK: - ProximitySettingsPane

private struct ProximitySettingsPane: View {

  // MARK: Internal

  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    Group {
      Section {
        Toggle(
          "Auto-lock when my iPhone leaves",
          isOn: Binding(
            get: { store.config.proximityAutoLock },
            set: { store.send(.proximityAutoLockToggled($0)) },
          ),
        )
        LabeledContent("Status", value: proximityStatusLine)
      } footer: {
        Text(
          "This Mac senses your iPhone over Bluetooth and locks when it leaves — no app on the phone. "
            + "Sign your iPhone into the same iCloud account so this Mac can recognize it across its "
            + "rotating Bluetooth address."
        )
      }

      if store.config.proximityAutoLock, !store.config.proximityDeviceID.isEmpty {
        ProximityPauseSection(store: store)
      }

      Section {
        ForEach(store.proximityDevices) { device in
          Button {
            store.send(.proximityDeviceSelected(device))
          } label: {
            HStack {
              Image(systemSymbol: .iphone).foregroundStyle(.secondary)
              Text(device.name)
              Spacer()
              Text("\(device.rssi) dBm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              if device.id.uuidString == store.config.proximityDeviceID {
                Image(systemSymbol: .checkmark).foregroundStyle(.tint)
              }
            }
          }
          .buttonStyle(.plain)
        }
        if store.proximityDevices.isEmpty {
          HStack {
            ProgressView().controlSize(.small)
            Text("Scanning for nearby devices…").foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Device")
      } footer: {
        Text("Pick your iPhone — hold it next to this Mac so it shows the strongest signal.")
      }

      Section {
        Picker(
          "Detection",
          selection: Binding(
            get: { store.config.proximityMode },
            set: { store.send(.proximityModeChanged($0)) },
          ),
        ) {
          ForEach(ProximityDetectionMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        if store.config.proximityMode == .smart {
          Picker(
            "Sensitivity",
            selection: Binding(
              get: { store.config.proximitySensitivity },
              set: { store.send(.proximitySensitivityChanged($0)) },
            ),
          ) {
            ForEach(ProximitySensitivity.allCases, id: \.self) { sensitivity in
              Text(sensitivity.title).tag(sensitivity)
            }
          }
          LabeledContent("Adaptive threshold", value: adaptiveThresholdLine)
          Button("Recalibrate nearby signal") {
            store.send(.proximityRecalibrateTapped)
          }
          .disabled(
            !store.config.proximityAutoLock
              || store.config.proximityDeviceID.isEmpty
              || store.activeAutoLockPause != nil
          )
        } else {
          manualControls
        }
      } header: {
        Text("Detection")
      } footer: {
        if store.config.proximityMode == .smart {
          Text(
            "Smart mode combines fast and stable signal filters, weak-signal consistency, departure trend, "
              + "and duration. Keyboard or pointer input cannot delay locking. Recalibrate with the iPhone "
              + "nearby after moving the Mac or changing where you normally keep the phone."
          )
        } else {
          Text(
            "Manual mode locks when the moving average remains weaker than your threshold for the selected "
              + "delay. It does not adapt to the room."
          )
        }
      }
    }
    .onAppear { store.send(.proximityScanToggled(true)) }
    .onDisappear { store.send(.proximityScanToggled(false)) }
  }

  // MARK: Private

  private var manualControls: some View {
    Group {
      Slider(
        value: Binding(
          get: { Double(store.config.proximityFarRSSI) },
          set: { store.send(.proximityFarRSSIChanged(Int($0.rounded()))) },
        ),
        in: -90.0 ... -40.0,
        step: 1,
      ) {
        Text("Lock threshold: \(store.config.proximityFarRSSI) dBm")
      } minimumValueLabel: {
        Text("Farther").font(.caption)
      } maximumValueLabel: {
        Text("Closer").font(.caption)
      }
      Picker(
        "Lock delay",
        selection: Binding(
          get: { store.config.proximityGraceSeconds },
          set: { store.send(.proximityGraceChanged($0)) },
        ),
      ) {
        Text("Instant").tag(0.0)
        Text("1 second").tag(1.0)
        Text("2 seconds").tag(2.0)
        Text("3 seconds").tag(3.0)
        Text("5 seconds").tag(5.0)
      }
      Slider(
        value: Binding(
          get: { Double(store.config.proximitySmoothing) },
          set: { store.send(.proximitySmoothingChanged(Int($0.rounded()))) },
        ),
        in: 1.0 ... 8.0,
        step: 1,
      ) {
        Text("Smoothing: \(store.config.proximitySmoothing) samples")
      } minimumValueLabel: {
        Text("Snappy").font(.caption)
      } maximumValueLabel: {
        Text("Smooth").font(.caption)
      }
    }
  }

  private var proximityStatusLine: String {
    if store.config.proximityAutoLock, store.config.proximityDeviceID.isEmpty {
      return "Pick your iPhone below"
    }
    if let pause = store.activeAutoLockPause {
      switch pause {
      case .until(let deadline):
        return "Paused until \(deadline.formatted(date: .abbreviated, time: .shortened))"
      case .whileCaffeinating:
        return "Paused while Caffeinate keeps the Mac unlocked"
      }
    }
    return statusText(store.proximityStatus)
  }

  private var adaptiveThresholdLine: String {
    switch store.proximityStatus {
    case .near(_, let threshold),
         .leaving(_, let threshold, _):
      "\(threshold) dBm"
    case .learning:
      "Learning…"
    default:
      "Available while monitoring"
    }
  }

  private func statusText(_ status: ProximityStatus) -> String {
    switch status {
    case .disabled: "Off"
    case .waitingForBluetooth(let reason): reason.summary
    case .searching: "Looking for your device…"
    case .learning(let rssi):
      rssi.map { "Learning nearby signal · \($0) dBm" } ?? "Learning nearby signal…"
    case .near(let rssi, _): "Nearby · \(rssi) dBm"
    case .leaving(let rssi, _, let remaining):
      remaining.map { "Possible departure · \(rssi) dBm · \($0)s" } ?? "Possible departure · \(rssi) dBm"
    case .reacquiring: "Reacquiring after Bluetooth or sleep…"
    case .away: "Left — locked"
    case .signalLost: "Signal lost — waiting for confirmation"
    }
  }

}

// MARK: - ProximityPauseSection

private struct ProximityPauseSection: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    Section {
      if let pause = store.activeAutoLockPause {
        switch pause {
        case .until(let deadline):
          LabeledContent(
            "Paused until",
            value: deadline.formatted(date: .abbreviated, time: .shortened),
          )

        case .whileCaffeinating:
          LabeledContent("Paused", value: "While Caffeinate keeps the Mac unlocked")
        }
        Button("Resume Auto-lock") {
          store.send(.proximityPauseResumeTapped)
        }
      } else {
        Menu("Pause for") {
          ForEach(AppFeature.ProximityPausePreset.allCases, id: \.self) { preset in
            Button(preset.title) {
              store.send(.proximityPausePresetSelected(preset))
            }
          }
        }
      }

      DatePicker(
        "Resume at",
        selection: $customPauseUntil,
        in: Date()...,
        displayedComponents: [.date, .hourAndMinute],
      )
      Button(store.proximityPauseUntil == nil ? "Pause until selected time" : "Change pause end time") {
        store.send(.proximityPauseUntilSelected(customPauseUntil))
      }
    } header: {
      Text("Temporary pause")
    } footer: {
      Text("Auto-lock resumes automatically at the selected time, even after Amado restarts.")
    }
    .onAppear {
      if let deadline = store.proximityPauseUntil {
        customPauseUntil = deadline
      } else {
        customPauseUntil = Date().addingTimeInterval(AppFeature.ProximityPausePreset.oneHour.rawValue)
      }
    }
  }

  // MARK: Private

  @State private var customPauseUntil = Date()

}

extension ProximityDetectionMode {
  fileprivate var title: String {
    switch self {
    case .smart: "Smart"
    case .manual: "Manual"
    }
  }
}

extension ProximitySensitivity {
  fileprivate var title: String {
    switch self {
    case .conservative: "Conservative"
    case .balanced: "Balanced"
    case .fast: "Fast"
    }
  }
}
