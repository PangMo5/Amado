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
      kind: AmadoService.lockWidgetKind,
      intent: SelectMacIntent.self,
      provider: LockProvider(),
    ) { entry in
      LockWidgetView(entry: entry)
    }
    .configurationDisplayName("Lock Mac")
    .description("Lock a paired Mac or refresh its current status.")
    .supportedFamilies([.systemSmall])
  }
}

// MARK: - LockEntry

struct LockEntry: TimelineEntry {
  let date: Date
  let mac: LockWidgetMac?
  let feedback: LockActionFeedback?
  /// True only for the WidgetKit placeholder shown while the entry loads, so the
  /// tile can show a spinner instead of stale/blank content.
  var isLoading = false
}

// MARK: - LockProvider

struct LockProvider: AppIntentTimelineProvider {

  // MARK: Internal

  func placeholder(in _: Context) -> LockEntry {
    LockEntry(date: Date(), mac: nil, feedback: nil, isLoading: true)
  }

  func snapshot(for configuration: SelectMacIntent, in _: Context) async -> LockEntry {
    entry(for: configuration)
  }

  func timeline(for configuration: SelectMacIntent, in _: Context) async -> Timeline<LockEntry> {
    let entry = entry(for: configuration)
    let policy: TimelineReloadPolicy =
      entry.feedback == nil
        ? .never
        : .after(entry.date.addingTimeInterval(LockActionFeedback.displayDuration))
    return Timeline(entries: [entry], policy: policy)
  }

  // MARK: Private

  private func entry(for configuration: SelectMacIntent) -> LockEntry {
    let now = Date()
    let mac = configuration.mac
      .flatMap(UUID.init(uuidString:))
      .flatMap { id in PairedMacsStore.load().first { $0.id == id } }
      .map { LockWidgetMac(id: $0.id, name: $0.displayName) }
    let feedback = mac.flatMap {
      LockActionFeedbackStore.load(surface: .widget, macID: $0.id, now: now)
    }
    return LockEntry(date: now, mac: mac, feedback: feedback)
  }

}

// MARK: - LockWidgetMac

struct LockWidgetMac: Equatable, Sendable {
  let id: UUID
  let name: String
}

// MARK: - LockWidgetView

struct LockWidgetView: View {

  let entry: LockEntry

  var body: some View {
    Group {
      if entry.isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let mac = entry.mac {
        ConfiguredLockWidgetView(mac: mac, feedback: entry.feedback)
      } else {
        UnconfiguredLockWidgetView()
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

}

// MARK: - ConfiguredLockWidgetView

private struct ConfiguredLockWidgetView: View {
  let mac: LockWidgetMac
  let feedback: LockActionFeedback?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        Button(intent: LockMacIntent(macID: mac.id.uuidString)) {
          WidgetGlyph(
            systemImage: feedback?.systemImage ?? "lock.fill",
            color: feedback?.isFailure == true ? .red : Color("BrandTint"),
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Lock \(mac.name)")

        Spacer()

        Button(intent: RefreshMacStatusIntent(macID: mac.id.uuidString)) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh \(mac.name) status")
      }

      Spacer(minLength: 8)

      Button(intent: LockMacIntent(macID: mac.id.uuidString)) {
        VStack(alignment: .leading, spacing: 0) {
          Text(mac.name)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Text(feedback?.widgetHint ?? "Tap to lock")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Lock \(mac.name)")
      .accessibilityHint(feedback?.widgetHint ?? "Tap to lock")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

// MARK: - UnconfiguredLockWidgetView

private struct UnconfiguredLockWidgetView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      WidgetGlyph(systemImage: "lock.fill", color: .secondary)

      Spacer(minLength: 8)

      Text("Choose a Mac")
        .font(.headline)
        .foregroundStyle(.primary)
      Text("Long-press to choose")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

// MARK: - WidgetGlyph

private struct WidgetGlyph: View {
  let systemImage: String
  let color: Color

  var body: some View {
    ZStack {
      Circle().fill(color.gradient)
      Image(systemName: systemImage)
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(.white)
    }
    .frame(width: 48, height: 48)
  }
}
