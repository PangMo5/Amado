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
        case .proximity: proximityPane
        case .remote: remotePane
        case .pairing: pairingPane
        case .about: aboutPane
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

  private var version: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    return "Version \(short)"
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

  private var proximityPane: some View {
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
      } header: {
        Text("Lock tuning")
      } footer: {
        Text(
          "Locks when the smoothed signal stays weaker than the threshold. Bluetooth "
            + "distance varies by phone and room, so calibrate: sit at your Mac, read "
            + "the “Nearby · –NN dBm” in Status above, then set the threshold a few dBm "
            + "weaker (more negative) — e.g. seated −48 → about −58. Delay is how long it "
            + "must stay past the threshold before locking. Smoothing averages that many "
            + "recent readings — fewer is snappier but noisier, more is steadier but slower."
        )
      }
    }
    .onAppear { store.send(.proximityScanToggled(true)) }
    .onDisappear { store.send(.proximityScanToggled(false)) }
  }

  private var proximityStatusLine: String {
    if store.config.proximityAutoLock, store.config.proximityDeviceID.isEmpty {
      return "Pick your iPhone below"
    }
    return statusText(store.proximityStatus)
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

  private var aboutPane: some View {
    Section {
      LabeledContent("Amado", value: version)
      Text("Lock your Mac from your iPhone or Apple Watch.")
        .foregroundStyle(.secondary)
      Button("Check for Updates…") { store.send(.checkForUpdatesTapped) }
      Text("© 2026 PangMo5")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private func statusText(_ status: ProximityStatus) -> String {
    switch status {
    case .disabled: "Off"
    case .waitingForBluetooth: "Turn on Bluetooth"
    case .searching: "Looking for your device…"
    case .near(let rssi): "Nearby · \(rssi) dBm"
    case .leaving(let rssi): "Signal weak · \(rssi) dBm"
    case .away: "Left — locked"
    case .signalLost: "Signal lost — locked"
    }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

}

private var hostName: String {
  Host.current().localizedName ?? "Mac"
}
