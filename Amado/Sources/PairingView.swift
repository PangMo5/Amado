import AmadoKit
import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

// MARK: - PairingView

/// The window a user opens to pair a device. The QR carries this Mac's name and
/// pairing secret; the phone finds it on the local network via Bonjour. Flips to
/// a ✓ and closes itself once a device completes pairing.
struct PairingView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    Group {
      if let device = store.justPairedWith {
        confirmation(device: device)
      } else {
        pairingContent
      }
    }
    .padding(28)
    .frame(width: 340)
    .onChange(of: store.justPairedWith) { _, paired in
      guard paired != nil else { return }
      Task {
        try? await Task.sleep(for: .seconds(1.8))
        dismissWindow(id: "pairing")
        store.send(.pairingWindowClosed)
      }
    }
  }

  // MARK: Private

  @Environment(\.dismissWindow) private var dismissWindow

  private var payloadString: String {
    PairingPayload(
      name: hostName,
      secret: store.pairingSecretBase64,
      remoteHost: store.config.remoteHost.isEmpty ? nil : store.config.remoteHost,
    ).encoded()
  }

  private var pairingContent: some View {
    VStack(spacing: 14) {
      Text("Pair a device")
        .font(.title2.weight(.semibold))
      Text("Scan this in the Amado app on your iPhone.")
        .font(.callout)
        .foregroundStyle(.secondary)

      qrCode

      reachabilityHint

      HStack(spacing: 12) {
        Button("Copy pairing code") { copy(payloadString) }
          .disabled(store.pairingSecretBase64.isEmpty)
        Button("Regenerate…") { store.send(.regenerateSecretTapped) }
      }
    }
  }

  private var reachabilityHint: some View {
    Label(
      store.config.remoteHost.isEmpty
        ? "Locks instantly on your local network"
        : "Locks on your network · anywhere via your tunnel",
      systemSymbol: .checkmarkSealFill,
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
  }

  @ViewBuilder
  private var qrCode: some View {
    if !store.pairingSecretBase64.isEmpty, let image = PairingQR.image(for: payloadString) {
      Image(decorative: image, scale: 1)
        .resizable()
        .interpolation(.none)
        .frame(width: 220, height: 220)
        .accessibilityLabel("Pairing QR code")
    } else {
      RoundedRectangle(cornerRadius: 8)
        .fill(.quaternary)
        .frame(width: 220, height: 220)
        .overlay(ProgressView())
    }
  }

  private func confirmation(device: String) -> some View {
    VStack(spacing: 16) {
      Image(systemSymbol: .checkmarkCircleFill)
        .font(.system(size: 64))
        .foregroundStyle(.green)
      Text("Paired with \(device)")
        .font(.title3.weight(.semibold))
        .multilineTextAlignment(.center)
    }
    .frame(height: 300)
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

}

private var hostName: String {
  Host.current().localizedName ?? "Mac"
}
