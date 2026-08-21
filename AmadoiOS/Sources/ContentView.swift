// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MPL-2.0

import AmadoKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

// MARK: - ContentView

struct ContentView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<LockSenderFeature>

  var body: some View {
    NavigationStack {
      List {
        if store.pairedMacs.isEmpty {
          PairingEmptyStateView(macAppURL: macAppURL)
        } else {
          Section("Your Macs") {
            ForEach(store.pairedMacs) { mac in
              PairedMacRow(
                mac: mac,
                lockStatus: store.macLockStatuses[mac.id],
                isSending: store.sendingMacID == mac.id,
                isDisabled: store.sendingMacID != nil,
                onLock: { store.send(.lockMac(mac.id)) },
              )
            }
            .onDelete { offsets in
              for index in offsets {
                store.send(.removeMac(store.pairedMacs[index].id))
              }
            }
          }

          Section("Quick Access") {
            NavigationLink {
              ControlCenterSettingsView(
                macs: store.pairedMacs,
                selectedMacID: store.controlCenterSelection.macID,
                onSelect: { store.send(.selectControlCenterMac($0)) },
              )
            } label: {
              QuickAccessRow(
                title: "Control Center",
                detail: controlCenterDetail,
                systemImage: "switch.2",
              )
            }
            QuickAccessRow(
              title: "Home Screen Widget",
              detail: "Add the Amado widget, then long-press it to choose a Mac.",
              systemImage: "square.grid.2x2",
            )
          }
        }

        DeviceIdentitySection(
          name: store.clientName,
          deviceID: store.clientID,
        )

        Section {
          Button {
            isScanning = true
          } label: {
            Label("Scan pairing QR", systemSymbol: .qrcodeViewfinder)
          }
          Button {
            store.send(.pasteTapped)
          } label: {
            Label("Paste pairing secret", systemSymbol: .docOnClipboard)
          }
          if !store.pairedMacs.isEmpty {
            Link(destination: macAppURL) {
              Label("Get Amado for Mac", systemImage: "arrow.down.app")
            }
          }
        } header: {
          Text("Add or re-pair a Mac")
        } footer: {
          Text("The free Amado for Mac menu bar app is required.")
        }
      }
      .navigationTitle("Amado")
      .safeAreaInset(edge: .bottom) {
        if let banner = store.banner {
          LockBannerView(
            banner: banner,
            onRetry: { store.send(.bannerRetryTapped) },
            onDismiss: { store.send(.bannerDismissed) },
          )
        }
      }
      .sheet(isPresented: $isScanning) {
        scannerSheet
      }
      .refreshable {
        await store.send(.refreshStatusesRequested).finish()
      }
      .task { await store.send(.task).finish() }
    }
  }

  // MARK: Private

  @State private var isScanning = false

  private let macAppURL = URL(string: "https://pangmo5.dev/Amado/")!

  private var controlCenterDetail: LocalizedStringResource {
    guard
      let selectedMacID = store.controlCenterSelection.macID,
      let mac = store.pairedMacs.first(where: { $0.id == selectedMacID })
    else {
      return "Choose which Mac the Lock Mac control uses."
    }
    return "Locks \(mac.displayName). Tap to choose another Mac."
  }

  private var scannerSheet: some View {
    NavigationStack {
      QRScannerView { code in
        store.send(.scanned(code))
        isScanning = false
      }
      .ignoresSafeArea()
      .navigationTitle("Scan pairing code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isScanning = false }
        }
      }
    }
  }

}

// MARK: - LockBannerView

/// The feedback strip above the tab bar. A failure is tinted, keeps its text
/// until dismissed, and offers to run the failed action again — the previous
/// version was an untinted line that scrolled past with no way to act on it.
private struct LockBannerView: View {

  // MARK: Internal

  let banner: LockBanner
  let onRetry: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      if banner.kind == .progress {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: symbol).foregroundStyle(tint)
      }

      Text(banner.message)
        .font(.callout)
        .foregroundStyle(banner.kind == .failure ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      if banner.retry != nil {
        Button("Retry", action: onRetry)
          .font(.callout.weight(.semibold))
      }
      if banner.kind != .progress {
        Button(action: onDismiss) {
          Image(systemSymbol: .xmark)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Dismiss")
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .background(.thinMaterial)
  }

  // MARK: Private

  private var symbol: String {
    switch banner.kind {
    case .success: "checkmark.circle.fill"
    case .failure: "exclamationmark.triangle.fill"
    case .progress: "ellipsis"
    }
  }

  private var tint: Color {
    switch banner.kind {
    case .success: .green
    case .failure: .orange
    case .progress: .secondary
    }
  }

}

// MARK: - DeviceIdentitySection

private struct DeviceIdentitySection: View {
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
      Text("This iPhone")
    } footer: {
      Text("Amado assigns this stable name from the device ID.")
    }
  }
}

// MARK: - PairedMacRow

private struct PairedMacRow: View {

  // MARK: Internal

  let mac: PairedMac
  let lockStatus: MacLockStatus?
  let isSending: Bool
  let isDisabled: Bool
  let onLock: () -> Void

  var body: some View {
    Button(action: onLock) {
      HStack {
        Image(systemSymbol: .desktopcomputer)
          .foregroundStyle(Color("BrandTint"))
        VStack(alignment: .leading, spacing: 2) {
          Text(mac.displayName)
          Text(statusLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isSending || lockStatus == .checking {
          ProgressView()
        } else {
          Image(systemName: statusSymbol)
            .foregroundStyle(statusTint)
        }
      }
    }
    .disabled(isDisabled)
  }

  // MARK: Private

  private var statusLabel: LocalizedStringResource {
    switch lockStatus {
    case .checking: "Checking status…"
    case .locked: "Locked"
    case .unlocked: "Unlocked"
    case .unavailable,
         nil: "Status unavailable"
    }
  }

  private var statusSymbol: String {
    switch lockStatus {
    case .locked: "lock.fill"
    case .unlocked: "lock.open.fill"
    case .checking,
         .unavailable,
         nil: "questionmark.circle"
    }
  }

  private var statusTint: Color {
    switch lockStatus {
    case .locked: Color.secondary
    case .unlocked: Color.accentColor
    case .checking,
         .unavailable,
         nil: Color.secondary
    }
  }

}

// MARK: - ControlCenterSettingsView

private struct ControlCenterSettingsView: View {
  let macs: [PairedMac]
  let selectedMacID: UUID?
  let onSelect: (UUID) -> Void

  var body: some View {
    List {
      Section {
        ForEach(macs) { mac in
          Button {
            onSelect(mac.id)
          } label: {
            HStack {
              Label(mac.displayName, systemSymbol: .desktopcomputer)
              Spacer()
              if selectedMacID == mac.id {
                Image(systemSymbol: .checkmark)
                  .foregroundStyle(.tint)
              }
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("Mac")
      } footer: {
        Text("The Lock Mac control in Control Center locks the selected Mac.")
      }
    }
    .navigationTitle("Control Center")
  }
}

// MARK: - PairingEmptyStateView

private struct PairingEmptyStateView: View {
  let macAppURL: URL

  var body: some View {
    VStack(spacing: 12) {
      Image(systemSymbol: .desktopcomputer)
        .font(.system(size: 40))
        .foregroundStyle(.secondary)

      Text("Pair your Mac")
        .font(.title2.bold())

      Text(
        "Install Amado for Mac, choose Show pairing code in the Mac menu, then scan or paste the code here."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)

      Link(destination: macAppURL) {
        Text("Get Amado for Mac")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
  }
}

// MARK: - QuickAccessRow

private struct QuickAccessRow: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let systemImage: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.headline)
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(Color("BrandTint").gradient, in: .circle)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}
