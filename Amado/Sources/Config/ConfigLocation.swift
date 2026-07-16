import Foundation

/// Resolves the location of Amado's `config.toml`, honoring the XDG Base
/// Directory spec when `XDG_CONFIG_HOME` is set. Mirrors Tatami's layout.
enum ConfigLocation {
  static let directoryName = "amado"
  static let filename = "config.toml"

  /// `$XDG_CONFIG_HOME/amado/` when set, otherwise `~/.config/amado/`.
  static var directory: URL {
    if
      let custom = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
      !custom.isEmpty
    {
      return URL(fileURLWithPath: custom, isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  static var fileURL: URL {
    directory.appendingPathComponent(filename, isDirectory: false)
  }

  /// Ensures the config directory exists. Idempotent. Call before the first
  /// write so `Data.write(to:)` doesn't fail on a missing parent.
  static func ensureDirectoryExists() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
}
