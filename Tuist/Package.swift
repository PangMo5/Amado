// swift-tools-version: 6.4

// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

#if TUIST
import ProjectDescription

/// Default to static linking: each dependency links into the target that uses
/// it, so nothing ships as an embedded dynamic framework — fast launch across
/// the phone, watch, and Mac agent. Sparkle is the exception: it is a binary
/// xcframework and is linked (dynamically) only by the macOS agent. Mirrors
/// the sibling Tatami project.
let packageSettings = PackageSettings(
  productTypes: [:]
)
#endif

let package = Package(
  name: "Amado",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.10.1"),
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "7.0.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    // HTTP server for the Mac agent's tunnel-facing endpoint (remote lock).
    // Linked only by the macOS `Amado` target — clients stay URLSession.
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.28.1"),
    // TOML config file for the Mac agent (~/.config/amado/config.toml), matching
    // Tatami. macOS-only. Product name is `TOML`.
    .package(url: "https://github.com/mattt/swift-toml", from: "2.1.0"),
  ],
)
