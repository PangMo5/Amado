import AmadoKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

struct WatchContentView: View {
  @Bindable var store: StoreOf<WatchLockFeature>

  var body: some View {
    NavigationStack {
      List {
        if store.macs.isEmpty {
          Text("Pair a Mac in the Amado app on your iPhone.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.macs) { mac in
            Button {
              store.send(.lockMac(mac.id))
            } label: {
              HStack {
                Image(systemSymbol: .lockFill)
                Text(mac.name)
                  .lineLimit(1)
                Spacer()
                if store.sendingMacID == mac.id {
                  ProgressView()
                }
              }
            }
            .disabled(store.sendingMacID != nil)
          }
        }

        if !store.status.isEmpty {
          Text(store.status)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Amado")
    }
    .task { await store.send(.task).finish() }
  }
}
