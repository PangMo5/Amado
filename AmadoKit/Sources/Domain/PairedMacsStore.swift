import Foundation

/// Where the phone (and its widget/control extensions) keep the list of paired
/// Macs. A file in the shared App Group container so the extension reads the
/// same list the app wrote; falls back to Documents if the group is missing.
public enum PairedMacsStore {
  public static var fileURL: URL {
    let directory = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: AmadoService.appGroup)
      ?? URL.documentsDirectory
    return directory.appending(path: "paired-macs.json")
  }

  /// Read the list directly (for widgets / App Intents that don't run TCA).
  /// Matches the JSON the app writes via `@Shared(.fileStorage(fileURL))`.
  public static func load() -> [PairedMac] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([PairedMac].self, from: data)) ?? []
  }
}
