// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

/// Default to static linking: each dependency links into the target that uses
/// it, so nothing ships as an embedded dynamic framework — fast launch across
/// the phone, watch, and Mac agent. Sparkle is the exception: it is a binary
/// xcframework and is linked (dynamically) only by the macOS agent. Mirrors
/// the sibling Tatami project.
let packageSettings = PackageSettings(
  productTypes: [:],
  targetSettings: [
    // Swift 6.3 whole-module compilation crashes while NIOPosix constructs a
    // ManagedAtomic for BaseSocketChannel on macOS 27. Keep Release
    // optimization, and remove these overrides after the dependencies or the
    // compiler resolve it.
    "Atomics": .settings(configurations: [
      .release(name: "Release", settings: [
        "SWIFT_COMPILATION_MODE": "singlefile"
      ])
    ]),
    "NIOPosix": .settings(configurations: [
      .release(name: "Release", settings: [
        "SWIFT_COMPILATION_MODE": "singlefile"
      ])
    ]),
  ],
)
#endif

let package = Package(
  name: "Amado",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.20.0"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.5.0"),
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "5.3.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    // HTTP server for the Mac agent's tunnel-facing endpoint (remote lock).
    // Linked only by the macOS `Amado` target — clients stay URLSession.
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
    // TOML config file for the Mac agent (~/.config/amado/config.toml), matching
    // Tatami. macOS-only. Product name is `TOML`.
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
  ],
)
