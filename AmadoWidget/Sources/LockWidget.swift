import AmadoKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - LockWidget

/// A configurable Home Screen widget: long-press to pick which paired Mac it
/// locks, then one tap fires `LockMacIntent` in the extension.
struct LockWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: "dev.PangMo5.Amado.LockWidget",
      intent: SelectMacIntent.self,
      provider: LockProvider(),
    ) { entry in
      LockWidgetView(entry: entry)
    }
    .configurationDisplayName("Lock Mac")
    .description("Lock a paired Mac with one tap.")
    .supportedFamilies([.systemSmall])
  }
}

// MARK: - LockEntry

struct LockEntry: TimelineEntry {
  let date: Date
  let mac: LockWidgetMac?
  /// True only for the WidgetKit placeholder shown while the entry loads, so the
  /// tile can show a spinner instead of stale/blank content.
  var isLoading = false
}

// MARK: - LockProvider

struct LockProvider: AppIntentTimelineProvider {
  func placeholder(in _: Context) -> LockEntry {
    LockEntry(date: Date(), mac: nil, isLoading: true)
  }

  func snapshot(for configuration: SelectMacIntent, in _: Context) async -> LockEntry {
    entry(for: configuration)
  }

  func timeline(for configuration: SelectMacIntent, in _: Context) async -> Timeline<LockEntry> {
    Timeline(entries: [entry(for: configuration)], policy: .never)
  }

  private func entry(for configuration: SelectMacIntent) -> LockEntry {
    let mac = configuration.mac
      .flatMap(UUID.init(uuidString:))
      .flatMap { id in PairedMacsStore.load().first { $0.id == id } }
      .map { LockWidgetMac(id: $0.id, name: $0.displayName) }
    return LockEntry(date: Date(), mac: mac)
  }
}

// MARK: - LockWidgetMac

struct LockWidgetMac: Equatable, Sendable {
  let id: UUID
  let name: String
}

// MARK: - LockWidgetView

struct LockWidgetView: View {

  // MARK: Internal

  let entry: LockEntry

  var body: some View {
    Group {
      if entry.isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let mac = entry.mac {
        Button(intent: LockMacIntent(macID: mac.id.uuidString)) {
          tile(name: mac.name, hint: "Tap to lock", glyphTint: true)
        }
        .buttonStyle(.plain)
      } else {
        tile(name: "Choose a Mac", hint: "Long-press to choose", glyphTint: false)
      }
    }
    .containerBackground(for: .widget) {
      LinearGradient(
        colors: [Color("BrandTint").opacity(0.28), Color("BrandTint").opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing,
      )
    }
  }

  // MARK: Private

  private func tile(name: String, hint: String, glyphTint: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack {
        Circle().fill(glyphTint ? AnyShapeStyle(Color("BrandTint").gradient) : AnyShapeStyle(.quaternary))
        Image(systemName: "lock.fill")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(glyphTint ? .white : .secondary)
      }
      .frame(width: 48, height: 48)

      Spacer(minLength: 8)

      Text(name)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(hint)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

}
