// swift-tools-version: 6.4

// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
  name: "ProjectGenerator",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "generate-project", targets: ["ProjectGenerator"])],
  dependencies: [
    .package(url: "https://github.com/apple/xcode-project-format", exact: "0.1.0")
  ],
  targets: [
    .executableTarget(
      name: "ProjectGenerator",
      dependencies: [.product(name: "XcodeProjectFormat", package: "xcode-project-format")],
    )
  ],
)
