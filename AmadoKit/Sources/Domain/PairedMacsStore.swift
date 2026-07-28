import Foundation

// MARK: - PairedMacsStore

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

  /// Remove a Mac after it reports that this phone was revoked. The iPhone app
  /// observes the same App Group file, so widget-originated cleanup also
  /// reaches the main app.
  public static func remove(id: UUID) {
    var paired = load()
    paired.removeAll { $0.id == id }
    guard let data = try? JSONEncoder().encode(paired) else { return }
    try? data.write(to: fileURL, options: .atomic)
    if ControlCenterMacStore.load().macID == id {
      ControlCenterMacStore.save(ControlCenterMacSelection(macID: paired.first?.id))
    }
  }

  /// Apply the authenticated identity returned by a Mac while preserving the
  /// phone-local record ID used by existing widget configuration.
  public static func updateIdentity(_ identity: PairedMacIdentity?, for id: UUID) {
    guard let identity else { return }
    var paired = load()
    guard let index = paired.firstIndex(where: { $0.id == id }) else { return }
    paired[index].apply(identity)
    guard let data = try? JSONEncoder().encode(paired) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}

// MARK: - PendingMacUnpairsStore

/// Phone-side tombstones for unpair requests that could not yet reach a Mac.
/// The iPhone app retries them on later launches so deletion is eventually
/// reflected on both devices even if the Mac was offline at the time.
public enum PendingMacUnpairsStore {
  public static var fileURL: URL {
    let directory = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: AmadoService.appGroup)
      ?? URL.documentsDirectory
    return directory.appending(path: "pending-mac-unpairs.json")
  }
}
