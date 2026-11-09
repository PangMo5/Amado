// swift-tools-version: 6.4

// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
  name: "AmadoPackage",
  platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
  products: [.library(name: "AmadoKit", targets: ["AmadoKit"])],
  targets: [
    .target(name: "AmadoKit"),
    .testTarget(name: "AmadoKitTests", dependencies: ["AmadoKit"]),
  ],
  swiftLanguageModes: [.v6],
)
