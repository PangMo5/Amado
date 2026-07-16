import AmadoKit
import AppIntents
import Foundation

// MARK: - MacEntity

/// A paired Mac exposed to the widget's configuration picker. Lives in the
/// widget target (not AmadoKit): App Intents metadata isn't reliably extracted
/// from a static framework, which left the config query stuck on "Loading…".
/// Shared logic (the paired-Macs file, the dispatcher) stays in AmadoKit.
struct MacEntity: AppEntity, Identifiable {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mac"
  static let defaultQuery = MacQuery()

  let id: UUID
  let name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

// MARK: - MacQuery

struct MacQuery: EntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [MacEntity] {
    all().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [MacEntity] {
    all()
  }

  private func all() -> [MacEntity] {
    PairedMacsStore.load().map { MacEntity(id: $0.id, name: $0.displayName) }
  }
}
