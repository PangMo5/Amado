import Foundation
import Sharing
import TOML

extension SharedReaderKey where Self == FileStorageKey<AmadoConfig>.Default {
  /// `@Shared(.amadoConfig)` reads/writes `~/.config/amado/config.toml`
  /// (TOML via swift-toml), falling back to an empty default when the file is
  /// missing so a fresh install just works. Serialization uses TOML so edits
  /// made outside the app are preserved. Mirrors Tatami's `tatamiConfig`.
  static var amadoConfig: Self {
    Self[
      .fileStorage(
        ConfigLocation.fileURL,
        decode: { data in
          try TOMLDecoder().decode(AmadoConfig.self, from: String(decoding: data, as: UTF8.self))
        },
        encode: { config in
          let encoder = TOMLEncoder()
          encoder.outputFormatting = [.sortedKeys]
          return try encoder.encode(config)
        },
      ),
      default: AmadoConfig(),
    ]
  }
}
