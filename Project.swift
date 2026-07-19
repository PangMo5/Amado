import ProjectDescription

let bundleIdPrefix = "dev.PangMo5"

// Injected at `tuist generate` time. Set these locally in `.mise.local.toml`
// (TUIST_DEVELOPMENT_TEAM, …); in CI they come from repository secrets.
let developmentTeam = Environment.developmentTeam.getString(default: "")
let sparklePublicEDKey = Environment.sparklePublicEdKey.getString(default: "")
let macOSVersion = "0.1.0"
let iOSVersion = "0.1.0"
// Release workflows inject the build number. Local builds use 1.
let buildNumber = Environment.buildNumber.getString(default: "1")

let iOSProvisioningProfile = Environment.iosProvisioningProfile.getString(default: "")
let watchProvisioningProfile = Environment.watchProvisioningProfile.getString(default: "")
let widgetProvisioningProfile = Environment.widgetProvisioningProfile.getString(default: "")

/// Shown on the local-network privacy prompt. Clients find the Mac via Bonjour
/// on the LAN.
let localNetworkUsage = "Amado connects to your Mac on the local network to lock it."

/// Bluetooth prompt for proximity auto-lock: the Mac scans for the owner's iPhone
/// (via its native BLE, no app on the phone) and locks itself when it leaves.
let bluetoothUsageMac = "Amado uses Bluetooth to sense when your iPhone leaves and lock this Mac."

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
  "SWIFT_VERSION": "6.0",
  "SWIFT_STRICT_CONCURRENCY": "complete",
  "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
  "DEAD_CODE_STRIPPING": "YES",
  // Sign with the developer's Apple Development cert locally so the binary
  // hash stays stable across rebuilds (otherwise macOS re-prompts for every
  // TCC / local-network permission). The release workflow overrides this.
  "CODE_SIGN_STYLE": "Automatic",
  "CODE_SIGN_IDENTITY": "Apple Development",
  // Hardened Runtime conflicts with development entitlements; off for local
  // debug builds. A release archive turns it back on for notarization.
  "ENABLE_HARDENED_RUNTIME": "NO",
]

let signingSettings: SettingsDictionary = [
  "CODE_SIGN_STYLE": "Automatic",
  "CODE_SIGN_IDENTITY": "Apple Development",
  "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
]

func mobileSigningSettings(provisioningProfile: String) -> SettingsDictionary {
  guard !provisioningProfile.isEmpty else { return signingSettings }

  return signingSettings.merging([
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "Apple Distribution",
    "PROVISIONING_PROFILE_SPECIFIER": SettingValue(stringLiteral: provisioningProfile),
  ]) { $1 }
}

let project = Project(
  name: "Amado",
  organizationName: "PangMo5",
  options: .options(
    automaticSchemesOptions: .enabled(),
    defaultKnownRegions: ["en"],
    developmentRegion: "en",
  ),
  settings: .settings(base: baseSettings),
  targets: [
    // MARK: - Amado (macOS menu-bar agent)

    .target(
      name: "Amado",
      destinations: .macOS,
      product: .app,
      bundleId: "\(bundleIdPrefix).Amado",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        // Menu-bar-only agent: no Dock icon, no main window on launch.
        "LSUIElement": true,
        "LSApplicationCategoryType": "public.app-category.utilities",
        "CFBundleDisplayName": "$(APP_DISPLAY_NAME)",
        "CFBundleName": "$(APP_DISPLAY_NAME)",
        "NSHumanReadableCopyright": "© 2026 PangMo5.",
        // macOS 15+ gates local-network listeners behind this prompt.
        "NSLocalNetworkUsageDescription": .string(localNetworkUsage),
        "NSBonjourServices": .array([.string("_amado._tcp")]),
        "NSBluetoothAlwaysUsageDescription": .string(bluetoothUsageMac),
        "SUFeedURL": "https://pangmo5.dev/Amado/appcast.xml",
        "SUEnableAutomaticChecks": true,
        "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
      ]),
      sources: ["Amado/Sources/**"],
      resources: ["Amado/Resources/**"],
      entitlements: .file(path: "Amado/Amado.entitlements"),
      dependencies: [
        .target(name: "AmadoKit"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Sharing"),
        .external(name: "Sparkle"),
        .external(name: "SFSafeSymbols"),
        // Tunnel-facing HTTP server (macOS agent only).
        .external(name: "Hummingbird"),
        // config.toml persistence (macOS agent only).
        .external(name: "TOML"),
      ],
      settings: .settings(
        base: signingSettings.merging([
          "MARKETING_VERSION": SettingValue(stringLiteral: macOSVersion),
          "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
          "SPARKLE_PUBLIC_ED_KEY": SettingValue(stringLiteral: sparklePublicEDKey),
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          "APP_DISPLAY_NAME": "Amado",
        ]) { $1 },
        configurations: [
          // Keep local permissions and launch-at-login registration separate
          // from an installed Developer ID release.
          .debug(name: "Debug", settings: [
            "PRODUCT_BUNDLE_IDENTIFIER": "\(bundleIdPrefix).Amado.debug",
            "APP_DISPLAY_NAME": "Amado Dev",
          ]),
          .release(name: "Release"),
        ],
      ),
    ),

    // MARK: - AmadoiOS (iPhone client)

    .target(
      name: "AmadoiOS",
      destinations: .iOS,
      product: .app,
      bundleId: "\(bundleIdPrefix).Amado.iOS",
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "CFBundleDisplayName": "Amado",
        "UILaunchScreen": .dictionary([:]),
        "NSLocalNetworkUsageDescription": .string(localNetworkUsage),
        "NSBonjourServices": .array([.string("_amado._tcp")]),
        "NSCameraUsageDescription": "Amado scans the pairing QR code shown on your Mac.",
        "ITSAppUsesNonExemptEncryption": false,
      ]),
      sources: ["AmadoiOS/Sources/**"],
      resources: ["AmadoiOS/Resources/**", "MobileResources/**"],
      entitlements: .file(path: "AmadoiOS/AmadoiOS.entitlements"),
      dependencies: [
        .target(name: "AmadoKit"),
        .target(name: "AmadoWatch"),
        .target(name: "AmadoWidget"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Sharing"),
        .external(name: "SFSafeSymbols"),
      ],
      settings: .settings(base: mobileSigningSettings(provisioningProfile: iOSProvisioningProfile).merging([
        "MARKETING_VERSION": SettingValue(stringLiteral: iOSVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "BrandTint",
      ]) { $1 }),
    ),

    // MARK: - AmadoWatch (Apple Watch client, companion of AmadoiOS)

    .target(
      name: "AmadoWatch",
      destinations: [.appleWatch],
      product: .app,
      bundleId: "\(bundleIdPrefix).Amado.iOS.watchkitapp",
      deploymentTargets: .watchOS("11.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "CFBundleDisplayName": "Amado",
        "WKApplication": true,
        "ITSAppUsesNonExemptEncryption": false,
        // Ties this watch app to the phone app so WatchConnectivity pairs them.
        "WKCompanionAppBundleIdentifier": "\(bundleIdPrefix).Amado.iOS",
      ]),
      sources: ["AmadoWatch/Sources/**"],
      resources: ["AmadoiOS/Resources/**", "MobileResources/**"],
      dependencies: [
        .target(name: "AmadoKit"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Sharing"),
        .external(name: "SFSafeSymbols"),
      ],
      settings: .settings(base: mobileSigningSettings(provisioningProfile: watchProvisioningProfile).merging([
        "MARKETING_VERSION": SettingValue(stringLiteral: iOSVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "BrandTint",
      ]) { $1 }),
    ),

    // MARK: - AmadoWidget (Home Screen widget + Control Center control)

    .target(
      name: "AmadoWidget",
      destinations: .iOS,
      product: .appExtension,
      bundleId: "\(bundleIdPrefix).Amado.iOS.Widget",
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: [
        // Must match the containing app's version or embedding fails validation.
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "CFBundleDisplayName": "Amado",
        "ITSAppUsesNonExemptEncryption": false,
        // The widget runs the lock intent in its own process, so it needs its
        // own Bonjour declaration — without it iOS blocks the browse and the
        // widget can't reach the agent even on the same network.
        "NSLocalNetworkUsageDescription": .string(localNetworkUsage),
        "NSBonjourServices": .array([.string("_amado._tcp")]),
        "NSExtension": .dictionary([
          "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
        ]),
      ]),
      sources: ["AmadoWidget/Sources/**"],
      resources: ["MobileResources/**"],
      entitlements: .file(path: "AmadoWidget/AmadoWidget.entitlements"),
      dependencies: [
        .target(name: "AmadoKit")
      ],
      settings: .settings(base: mobileSigningSettings(provisioningProfile: widgetProvisioningProfile).merging([
        "MARKETING_VERSION": SettingValue(stringLiteral: iOSVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "BrandTint",
      ]) { $1 }),
    ),

    // MARK: - AmadoKit (shared core — models, transport, crypto)

    .target(
      name: "AmadoKit",
      destinations: [.mac, .iPhone, .iPad, .appleWatch],
      product: .staticFramework,
      bundleId: "\(bundleIdPrefix).Amado.Kit",
      deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0", watchOS: "11.0"),
      // Pure, dependency-free core (Foundation + CryptoKit) so it builds
      // cleanly on all three platforms. TCA/Sharing live on the app targets.
      sources: ["AmadoKit/Sources/**"],
      dependencies: [],
    ),

    // MARK: - AmadoTests

    .target(
      name: "AmadoTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "\(bundleIdPrefix).Amado.Tests",
      deploymentTargets: .macOS("15.0"),
      sources: ["AmadoTests/Sources/**"],
      dependencies: [
        .target(name: "AmadoKit")
      ],
    ),
  ],
)
