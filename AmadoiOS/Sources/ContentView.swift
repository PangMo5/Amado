import AmadoKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

struct ContentView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<LockSenderFeature>

  var body: some View {
    NavigationStack {
      List {
        if store.pairedMacs.isEmpty {
          emptyState
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
        }

        Section("Add / re-pair a Mac") {
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

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Macs paired", systemSymbol: .desktopcomputer)
    } description: {
      Text("On your Mac: Amado menu → “Show pairing code…”, then scan it or paste the secret.")
    }
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
