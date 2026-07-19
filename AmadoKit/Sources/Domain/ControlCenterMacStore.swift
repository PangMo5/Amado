import Foundation

// MARK: - ControlCenterMacSelection

public struct ControlCenterMacSelection: Codable, Equatable, Sendable {
  public init(macID: UUID? = nil) {
    self.macID = macID
  }

  public var macID: UUID?
}

// MARK: - ControlCenterMacStore

/// Stores the Mac chosen for the static Control Center control in the shared
/// App Group container, where both the iPhone app and widget extension can use it.
public enum ControlCenterMacStore {
  public static var fileURL: URL {
    let directory = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: AmadoService.appGroup)
      ?? URL.documentsDirectory
    return directory.appending(path: "control-center-mac.json")
  }

  public static func load() -> ControlCenterMacSelection {
    guard let data = try? Data(contentsOf: fileURL) else { return ControlCenterMacSelection() }
    return (try? JSONDecoder().decode(ControlCenterMacSelection.self, from: data))
      ?? ControlCenterMacSelection()
  }
}
