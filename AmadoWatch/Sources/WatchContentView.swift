import AmadoKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

// MARK: - WatchContentView

struct WatchContentView: View {
  @Bindable var store: StoreOf<WatchLockFeature>

  var body: some View {
    NavigationStack {
      if store.macs.isEmpty {
        WatchSetupView()
      } else {
        WatchMacList(
          macs: store.macs,
          sendingMacID: store.sendingMacID,
          status: store.status,
          onLock: { store.send(.lockMac($0)) },
        )
      }
    }
    .task { await store.send(.task).finish() }
  }
}

// MARK: - WatchSetupView

private struct WatchSetupView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(Color("BrandTint").gradient)
          Image(systemSymbol: .iphone)
            .font(.title2.bold())
            .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)

        Text("Set up on iPhone")
          .font(.headline)

        Text("Pair a Mac in Amado on iPhone. Already paired? Open the app to sync.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)
    }
    .navigationTitle("Amado")
  }
}

// MARK: - WatchMacList

private struct WatchMacList: View {
  let macs: [WatchMac]
  let sendingMacID: UUID?
  let status: String
  let onLock: (UUID) -> Void

  var body: some View {
    List {
      ForEach(macs) { mac in
        Button {
          onLock(mac.id)
        } label: {
          HStack(spacing: 10) {
            ZStack {
              Circle()
                .fill(Color("BrandTint").gradient)
              Image(systemSymbol: .lockFill)
                .font(.caption.bold())
                .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
              Text(mac.name)
                .font(.headline)
                .lineLimit(1)
              Text("Tap to lock")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if sendingMacID == mac.id {
              ProgressView()
            }
          }
        }
        .disabled(sendingMacID != nil)
      }

      WatchQuickAccessSection()

      if !status.isEmpty {
        Text(status)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Amado")
  }
}

// MARK: - WatchQuickAccessSection

private struct WatchQuickAccessSection: View {
  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 10) {
        ZStack {
          Circle()
            .fill(Color("BrandTint").gradient)
          Image(systemName: "switch.2")
            .font(.caption.bold())
            .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 1) {
          Text("Control Center")
            .font(.headline)
          Text("Add Amado for one-tap locking.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 7)
    } header: {
      Text("Quick Access")
    }
  }
}
