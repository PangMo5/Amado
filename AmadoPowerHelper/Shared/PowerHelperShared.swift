// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

// MARK: - PowerHelperProtocol

/// The deliberately narrow XPC surface exposed by Amado's root helper.
///
/// The helper can only acquire or release a lease for `pmset disablesleep`.
/// It cannot execute arbitrary commands or accept command-line arguments from
/// the app.
@objc(AmadoPowerHelperProtocol)
protocol PowerHelperProtocol: AnyObject {
  func getBuild(
    withReply reply: @escaping @Sendable (_ version: String, _ build: String) -> Void
  )

  func setClosedLidMode(
    _ enabled: Bool,
    withReply reply: @escaping @Sendable (Bool) -> Void,
  )
}

// MARK: - PowerHelperBuild

/// Identifies the exact helper bundled with the running app. Service
/// Management keeps an already-registered daemon instead of replacing it, so
/// the app verifies this handshake before acquiring a sleep-override lease.
struct PowerHelperBuild: Equatable, Sendable {
  static var current: Self {
    let info = Bundle.main.infoDictionary
    return Self(
      version: info?["CFBundleShortVersionString"] as? String ?? "",
      build: info?["CFBundleVersion"] as? String ?? "",
    )
  }

  let version: String
  let build: String

  var displayName: String {
    "\(version) (\(build))"
  }

  var isValid: Bool {
    !version.isEmpty && !build.isEmpty
  }
}

// MARK: - PowerHelperIdentity

struct PowerHelperIdentity: Equatable, Sendable {
  static let release = Self(
    helperIdentifier: "dev.PangMo5.Amado.PowerHelper",
    plistName: "dev.PangMo5.Amado.PowerHelper.plist",
  )
  static let debug = Self(
    helperIdentifier: "dev.PangMo5.Amado.debug.PowerHelper",
    plistName: "dev.PangMo5.Amado.debug.PowerHelper.plist",
  )

  let helperIdentifier: String
  let plistName: String

  var machServiceName: String {
    helperIdentifier
  }

  func isBundled(in appBundleURL: URL, fileManager: FileManager = .default) -> Bool {
    let contentsURL = appBundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    let plistURL = contentsURL
      .appending(path: "Library/LaunchDaemons", directoryHint: .isDirectory)
      .appending(path: plistName)
    let executableURL = contentsURL
      .appending(path: "MacOS", directoryHint: .isDirectory)
      .appending(path: "AmadoPowerHelper")
    return fileManager.fileExists(atPath: plistURL.path)
      && fileManager.isExecutableFile(atPath: executableURL.path)
  }
}

// MARK: - PowerHelperConstants

enum PowerHelperConstants {
  static let appIdentifiers = [
    "dev.PangMo5.Amado",
    "dev.PangMo5.Amado.debug",
  ]

  #if DEBUG
  static let identity = PowerHelperIdentity.debug
  #else
  static let identity = PowerHelperIdentity.release
  #endif

  static var helperIdentifier: String {
    identity.helperIdentifier
  }

  static var machServiceName: String {
    identity.machServiceName
  }

  static var plistName: String {
    identity.plistName
  }
}

// MARK: - PowerHelperCodeSigning

/// Builds peer requirements for the XPC channel from the current process's
/// signing team. Both sides fail closed when there is no Apple signing team.
enum PowerHelperCodeSigning {
  static func currentTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }

    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information,
      ) == errSecSuccess,
      let dictionary = information as? [String: Any]
    else { return nil }

    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
  }

  static func sameTeamRequirement(identifiers: [String]) -> String? {
    guard let teamIdentifier = currentTeamIdentifier(), !identifiers.isEmpty else { return nil }
    let identifiers = identifiers
      .map { "identifier \"\($0)\"" }
      .joined(separator: " or ")
    return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
      + "and (\(identifiers))"
  }
}
