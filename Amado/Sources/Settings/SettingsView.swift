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
      case .remote: "Remote access"
      case .pairing: "Pairing"
      case .about: "About"
      }
    }

    var icon: SFSymbol {
      switch self {
      case .general: .gearshape
      case .proximity: .figureWalk
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
    PairingPayload(
      name: hostName,
      secret: store.pairingSecretBase64,
      remoteHost: store.config.remoteHost.isEmpty ? nil : store.config.remoteHost,
    ).encoded()
  }

  private var generalPane: some View {
    Group {
      Section {
        Toggle(
          "Launch at Login",
          isOn: Binding(
            get: { store.launchAtLogin },
            set: { store.send(.launchAtLoginToggled($0)) },
          ),
        )
        LabeledContent("Status", value: store.isListening ? "Listening" : "Starting…")
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
          Text("Secure remote and walk-away Mac locking")
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
          .disabled(!store.config.proximityAutoLock || store.config.proximityDeviceID.isEmpty)
        } else {
          manualControls
        }
      } header: {
        Text("Detection")
      } footer: {
        if store.config.proximityMode == .smart {
          Text(
            "Smart mode learns the nearby signal, rejects brief spikes, follows the departure trend, "
              + "and avoids borderline locks while this Mac is in use. Recalibrate with the iPhone nearby "
              + "after moving the Mac or changing where you normally keep the phone."
          )
        } else {
          Text(
            "Manual mode locks when the moving average remains weaker than your threshold for the selected "
              + "delay. It does not adapt to the room or recent Mac activity."
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
    return statusText(store.proximityStatus)
  }

  private var adaptiveThresholdLine: String {
    switch store.proximityStatus {
    case .near(_, let threshold),
         .leaving(_, let threshold, _),
         .pausedByActivity(_, let threshold):
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
    case .waitingForBluetooth: "Turn on Bluetooth"
    case .searching: "Looking for your device…"
    case .learning(let rssi):
      rssi.map { "Learning nearby signal · \($0) dBm" } ?? "Learning nearby signal…"
    case .near(let rssi, _): "Nearby · \(rssi) dBm"
    case .leaving(let rssi, _, let remaining):
      remaining.map { "Possible departure · \(rssi) dBm · \($0)s" } ?? "Possible departure · \(rssi) dBm"
    case .pausedByActivity(let rssi, _): "Weak signal, but this Mac is in use · \(rssi) dBm"
    case .reacquiring: "Reacquiring after Bluetooth or sleep…"
    case .away: "Left — locked"
    case .signalLost: "Signal lost — waiting for confirmation"
    }
  }

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

private var hostName: String {
  Host.current().localizedName ?? "Mac"
}
