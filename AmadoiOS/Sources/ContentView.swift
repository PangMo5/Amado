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
              macRow(mac)
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
        if !store.status.isEmpty {
          Text(store.status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.thinMaterial)
        }
      }
      .sheet(isPresented: $isScanning) {
        scannerSheet
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

  private func macRow(_ mac: PairedMac) -> some View {
    Button {
      store.send(.lockMac(mac.id))
    } label: {
      HStack {
        Image(systemSymbol: .desktopcomputer)
          .foregroundStyle(.secondary)
        Text(mac.displayName)
        Spacer()
        if store.sendingMacID == mac.id {
          ProgressView()
        } else {
          Image(systemSymbol: .lockFill)
            .foregroundStyle(.tint)
        }
      }
    }
    .disabled(store.sendingMacID != nil)
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
