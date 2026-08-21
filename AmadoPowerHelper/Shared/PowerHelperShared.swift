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
  func setClosedLidMode(
    _ enabled: Bool,
    withReply reply: @escaping @Sendable (Bool) -> Void,
  )
}

// MARK: - PowerHelperConstants

enum PowerHelperConstants {
  static let appIdentifiers = [
    "dev.PangMo5.Amado",
    "dev.PangMo5.Amado.debug",
  ]
  static let helperIdentifier = "dev.PangMo5.Amado.PowerHelper"
  static let machServiceName = helperIdentifier
  static let plistName = "dev.PangMo5.Amado.PowerHelper.plist"
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
