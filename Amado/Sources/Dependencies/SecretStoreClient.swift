import AmadoKit
import Dependencies
import DependenciesMacros
import Foundation
import Security

// MARK: - SecretStoreClient

/// The Mac agent's pairing secret, persisted in the login Keychain rather than
/// config.toml — it's an HMAC key, so it stays out of a hand-editable file.
/// Read on `.task` and rewritten on regenerate; the HTTP server reads it
/// directly via `AmadoKeychain`.
@DependencyClient
struct SecretStoreClient: Sendable {
  var load: @Sendable () -> String?
  var save: @Sendable (String) -> Void
}

// MARK: DependencyKey

extension SecretStoreClient: DependencyKey {
  static let liveValue = SecretStoreClient(
    load: {
      AmadoKeychain.migrateLegacyIfNeeded()
      return AmadoKeychain.loadSecret()
    },
    save: { AmadoKeychain.saveSecret($0) },
  )

  static let testValue = SecretStoreClient(load: { nil }, save: { _ in })
  static let previewValue = testValue
}

extension DependencyValues {
  var secretStore: SecretStoreClient {
    get { self[SecretStoreClient.self] }
    set { self[SecretStoreClient.self] = newValue }
  }
}

// MARK: - AmadoKeychain

/// Login-Keychain storage for the pairing secret (base64). Used by both the
/// reducer (via `SecretStoreClient`) and the HTTP server's HMAC verifier.
enum AmadoKeychain {

  // MARK: Internal

  static func loadSecret() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let secret = String(data: data, encoding: .utf8)
    else { return nil }
    return secret
  }

  static func saveSecret(_ secret: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    // Upsert: clear any existing item, then add the new one.
    SecItemDelete(base as CFDictionary)
    var attributes = base
    attributes[kSecValueData as String] = Data(secret.utf8)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(attributes as CFDictionary, nil)
  }

  /// One-time migration of the pre-Keychain secret from UserDefaults. No-op once
  /// the Keychain holds a value.
  static func migrateLegacyIfNeeded() {
    guard loadSecret() == nil else { return }
    guard
      let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey),
      !legacy.isEmpty
    else { return }
    saveSecret(legacy)
    UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
  }

  // MARK: Private

  private static let service = "dev.PangMo5.Amado"
  private static let account = "pairingSecret"
  /// Pre-Keychain location, migrated once then removed.
  private static let legacyDefaultsKey = "amado.pairingSecret"

}
