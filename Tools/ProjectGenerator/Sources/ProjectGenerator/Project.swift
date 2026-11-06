// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import XcodeProjectFormat

typealias Schema = XCSchema

// MARK: - GenerateProject

/// Generates only the native app containers. SwiftPM owns the shared module
/// and all third-party dependencies; synchronized folders own source membership.
@main
enum GenerateProject {
  static func main() throws {
    let check = CommandLine.arguments.contains("--check")
    let root = URL(filePath: FileManager.default.currentDirectoryPath)
    guard FileManager.default.fileExists(atPath: root.appending(path: "AmadoPackage/Package.swift").path) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Run from the Amado repository root."])
    }

    let project = try makeProject()
    var outputs: [String: Data] = [
      "Amado.xcodeproj/project.xcproj": try project.jsonRepresentation(),
      "Amado.xcworkspace/contents.xcworkspacedata": Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0">
          <FileRef location="group:Amado.xcodeproj" />
          <FileRef location="group:AmadoPackage" />
        </Workspace>

        """.utf8),
    ]
    for target in project.targets {
      let name = target.name
      outputs["Amado.xcodeproj/xcshareddata/xcschemes/\(name).xcscheme"] = Data(scheme(for: name).utf8)
    }
    for (path, data) in outputs.sorted(by: { $0.key < $1.key }) {
      let url = root.appending(path: path)
      if check {
        guard try Data(contentsOf: url) == data else {
          throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(path) is stale. Run make generate."])
        }
      } else {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      }
    }
    print(check ? "Project generation is up to date." : "Generated Amado.xcodeproj/project.xcproj and shared schemes.")
  }

  static func makeProject() throws -> Schema.Project {
    // Declare modules used directly by app sources and reducer macro expansions.
    // Native SwiftPM may build shared app/test dependencies as dynamic products;
    // importing a transitive module alone does not link that product into an app.
    let clientProducts = [
      "AmadoKit",
      "ComposableArchitecture",
      "Sharing",
      "SFSafeSymbols",
      "Dependencies",
      "DependenciesMacros",
      "CasePaths",
    ]
    let macProducts = clientProducts + ["Sparkle", "Hummingbird", "TOML"]
    let targets: [Schema.Target] = [
      target(
        "Amado",
        type: "application",
        sdk: "macosx",
        minimumOS: "15.0",
        products: macProducts,
        dependencies: ["AmadoPowerHelper"],
        settings: [
          "MARKETING_VERSION": "$(AMADO_MACOS_VERSION)",
          "CODE_SIGN_ENTITLEMENTS": "Amado/Amado.entitlements",
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
          "COMBINE_HIDPI_IMAGES": "YES",
          "ENABLE_PREVIEWS": "YES",
          "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        ],
        phases: [
          copyPhase("Embed Power Helper", base: .executablesDir),
          .script(.init(
            objectID: nil,
            name: "Install Power Helper LaunchDaemon",
            shellPath: "/bin/sh",
            script: """
              set -eu
              destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchDaemons"
              /bin/mkdir -p "$destination"
              /usr/bin/install -m 644 "${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"
              """,
            logEnvironmentVariables: false,
            inputPaths: ["$(SRCROOT)/AmadoPowerHelper/Resources/$(PRODUCT_BUNDLE_IDENTIFIER).PowerHelper.plist"],
            inputFileListPaths: [],
            outputPaths: [
              "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchDaemons/$(PRODUCT_BUNDLE_IDENTIFIER).PowerHelper.plist"
            ],
            outputFileListPaths: [],
            dependencyFile: nil,
            runOnEveryBuild: false,
            scope: .always,
          )),
        ],
        configurations: [configuration("Debug", file: "AmadoDebug"), configuration("Release", file: "AmadoRelease")],
      ),
      target(
        "AmadoPowerHelper",
        type: "tool",
        sdk: "macosx",
        minimumOS: "15.0",
        settings: [
          "MARKETING_VERSION": "$(AMADO_MACOS_VERSION)",
          "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
          "SKIP_INSTALL": "YES",
        ],
        configurations: [
          configuration("Debug", file: "AmadoPowerHelperDebug"),
          configuration("Release", file: "AmadoPowerHelperRelease"),
        ],
      ),
      target(
        "AmadoiOS",
        type: "application",
        sdk: "iphoneos",
        minimumOS: "18.0",
        bundleID: "dev.PangMo5.Amado.iOS",
        products: clientProducts,
        dependencies: ["AmadoWatch", "AmadoWidget"],
        settings: [
          "CODE_SIGN_ENTITLEMENTS": "AmadoiOS/AmadoiOS.entitlements",
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          "TARGETED_DEVICE_FAMILY": "1",
          "ENABLE_PREVIEWS": "YES",
          "PROVISIONING_PROFILE_SPECIFIER": "$(AMADO_IOS_PROVISIONING_PROFILE)",
        ],
        phases: [
          copyPhase("Embed Watch Content", base: .productDir, path: "$(CONTENTS_FOLDER_PATH)/Watch"),
          copyPhase("Embed App Extensions", base: .plugInsDir),
        ],
      ),
      target(
        "AmadoWatch",
        type: "application",
        sdk: "watchos",
        minimumOS: "11.0",
        bundleID: "dev.PangMo5.Amado.iOS.watchkitapp",
        products: clientProducts,
        settings: [
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          "TARGETED_DEVICE_FAMILY": "4",
          "ENABLE_PREVIEWS": "YES",
          "SKIP_INSTALL": "YES",
          "PROVISIONING_PROFILE_SPECIFIER": "$(AMADO_WATCH_PROVISIONING_PROFILE)",
        ],
      ),
      target(
        "AmadoWidget",
        type: "app-extension",
        sdk: "iphoneos",
        minimumOS: "18.0",
        bundleID: "dev.PangMo5.Amado.iOS.Widget",
        products: ["AmadoKit"],
        settings: [
          "CODE_SIGN_ENTITLEMENTS": "AmadoWidget/AmadoWidget.entitlements",
          "TARGETED_DEVICE_FAMILY": "1",
          "APPLICATION_EXTENSION_API_ONLY": "YES",
          "SKIP_INSTALL": "YES",
          "PROVISIONING_PROFILE_SPECIFIER": "$(AMADO_WIDGET_PROVISIONING_PROFILE)",
        ],
      ),
      target(
        "AmadoTests",
        type: "bundle.unit-test",
        sdk: "macosx",
        minimumOS: "15.0",
        bundleID: "dev.PangMo5.Amado.Tests",
        products: [
          "AmadoKit",
          "ComposableArchitecture",
          "Sharing",
          "TOML",
          "Dependencies",
          "DependenciesMacros",
          "CasePaths",
          "ConcurrencyExtras",
        ],
        dependencies: ["Amado"],
        settings: [
          "GENERATE_INFOPLIST_FILE": "YES",
          "BUNDLE_LOADER": "$(TEST_HOST)",
          "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Amado.app/Contents/MacOS/Amado",
          "TEST_TARGET_NAME": "Amado",
          "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks",
        ],
      ),
    ]

    var files: [Schema.Reference] = try [
      sourceGroup("Amado", resources: true),
      sourceGroup("AmadoiOS", resourceTargets: ["AmadoiOS", "AmadoWatch"]),
      sourceGroup("AmadoWatch"),
      sourceGroup("AmadoWidget"),
      sourceGroup("AmadoTests", infoPlist: false),
      .group(.init(
        objectID: nil,
        name: "AmadoPowerHelper",
        path: "AmadoPowerHelper",
        includeInIndex: nil,
        children: [
          folder("Sources", targets: ["AmadoPowerHelper"]),
          folder("Shared", targets: ["Amado", "AmadoPowerHelper"]),
          folder("Resources"),
          file("Info.plist"),
        ],
      )),
      folder("Configuration"),
      folder("MobileResources", targets: ["AmadoiOS", "AmadoWatch", "AmadoWidget"]),
      resource("LICENSE", targets: ["Amado"]),
      resource("LICENSES/MPL-2.0.txt", targets: ["Amado", "AmadoiOS"]),
      resource("NOTICE.md", targets: ["Amado", "AmadoiOS"]),
    ]
    files.append(.group(.init(
      objectID: nil,
      name: "Products",
      path: "",
      includeInIndex: nil,
      children: try targets.map { target in
        let name = productName(target.name)
        let membership: [Schema.ProjectBuildFile] =
          switch target.name {
          case "AmadoPowerHelper": [buildFile("Amado", kind: .copy, name: "Embed Power Helper", sign: true)]
          case "AmadoWatch": [buildFile("AmadoiOS", kind: .copy, name: "Embed Watch Content", sign: true)]
          case "AmadoWidget": [buildFile("AmadoiOS", kind: .copy, name: "Embed App Extensions", sign: true)]
          default: []
          }
        return try file(name, base: .buildProducts, buildFiles: membership)
      },
    )))

    let remotePackages: [(String, String)] = [
      ("pointfreeco/swift-composable-architecture", "1.26.2"),
      ("pointfreeco/swift-sharing", "2.10.1"),
      ("pointfreeco/swift-dependencies", "1.17.2"),
      ("pointfreeco/swift-case-paths", "1.10.0"),
      ("pointfreeco/swift-concurrency-extras", "1.4.3"),
      ("SFSafeSymbols/SFSafeSymbols", "7.0.0"),
      ("sparkle-project/Sparkle", "2.10.1"),
      ("hummingbird-project/hummingbird", "2.28.1"),
      ("mattt/swift-toml", "2.1.0"),
    ]
    return Schema.Project(
      objectID: id("Project"),
      rootGroupDebugID: nil,
      configurationListDebugID: nil,
      topLevelReferences: files,
      packages: [.init(location: .local(.init(path: "AmadoPackage")), traits: [])] + remotePackages.map { repository, version in
        .init(
          location: .remote(.init(repositoryURL: "https://github.com/\(repository)", versionConstraint: .version(version))),
          traits: [],
        )
      },
      configurations: [configuration("Debug", file: "Debug"), configuration("Release", file: "Release")],
      buildSettings: [:],
      defaultConfigurationName: .init(rawValue: "Debug"),
      targets: targets,
      localizationInfo: .init(development: .init(languageID: "en"), supported: [.init(languageID: "Base")]),
      requiredCapabilities: [],
      buildIndependentTargetsInParallel: true,
      lastUpgradeCheck: nil,
      lastSwiftUpdateCheck: nil,
      lastSwiftMigration: nil,
      organizationName: "PangMo5",
      classPrefix: nil,
      productsGroup: reference("Products"),
      importedProducts: [],
    )
  }

  static func target(
    _ name: String,
    type: String,
    sdk: String,
    minimumOS: String,
    bundleID: String? = nil,
    products: [String] = [],
    dependencies: [String] = [],
    settings: [String: String] = [:],
    phases: [Schema.BuildPhase] = [],
    configurations: [Schema.Configuration] = [],
  ) -> Schema.Target {
    let deploymentSetting =
      switch sdk {
      case "iphoneos": "IPHONEOS_DEPLOYMENT_TARGET"
      case "watchos": "WATCHOS_DEPLOYMENT_TARGET"
      default: "MACOSX_DEPLOYMENT_TARGET"
      }
    var buildSettings = [
      "PRODUCT_NAME": name,
      "SDKROOT": sdk,
      "SUPPORTED_PLATFORMS": sdk == "iphoneos"
        ? "iphoneos iphonesimulator"
        : sdk == "watchos" ? "watchos watchsimulator" : "macosx",
      deploymentSetting: minimumOS,
      "GENERATE_INFOPLIST_FILE": "NO",
      "MARKETING_VERSION": "$(AMADO_IOS_VERSION)",
    ]
    if sdk != "macosx" {
      buildSettings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "BrandTint"
      buildSettings["LD_RUNPATH_SEARCH_PATHS"] = type == "app-extension"
        ? "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"
        : "$(inherited) @executable_path/Frameworks"
    }
    if sdk == "iphoneos" {
      buildSettings["SUPPORTS_MACCATALYST"] = "NO"
      buildSettings["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] = "YES"
      buildSettings["SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD"] = "NO"
    }
    if name != "AmadoTests" {
      buildSettings["INFOPLIST_FILE"] = "\(name)/Info.plist"
    }
    if let bundleID {
      buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] = bundleID
    }
    buildSettings.merge(settings) { _, new in new }
    return .native(.init(
      name: name,
      objectID: id(name),
      configurationListDebugID: nil,
      dependencies: dependencies.map { .localTarget(.init(targetName: $0), []) },
      buildPhases: [
        .sources(.init(objectID: nil, name: nil)),
        .frameworks(.init(objectID: nil, name: nil)),
        .resources(.init(objectID: nil, name: nil)),
      ] + phases,
      buildRules: [],
      specializedConfigurations: configurations,
      buildSettings: buildSettings.mapValues(Schema.BuildSetting.string),
      product: reference("Products", productName(name)),
      productTypeID: .init(abbreviatedRepresentation: type),
      testHostTarget: name == "AmadoTests" ? .init(targetName: "Amado") : nil,
      legacyProvisioningStyle: nil,
      legacyTeamID: nil,
      lastSwiftUpdateCheck: nil,
      lastSwiftMigration: nil,
      // SwiftPM embeds dynamic products, including Sparkle's binary framework.
      // Copy phases are only needed for the native helper, Watch, and Widget.
      packageProductTargetMembers: products.map(packageMember),
    ))
  }

  static func id(_ name: String) -> Schema.ObjectID {
    .init(SHA256.hash(data: Data("dev.PangMo5.Amado.\(name)".utf8)).prefix(12).map { String(format: "%02X", $0) }.joined())
  }

  static func reference(_ names: String...) -> Schema.GroupTreeReference {
    .namePath(.init(components: names.map(Schema.NamePathComponent.child)))
  }

  static func configuration(_ name: String, file: String) -> Schema.Configuration {
    .init(
      name: .init(rawValue: name),
      file: .init(anchor: reference("Configuration"), relativePath: .init(components: [.child("\(file).xcconfig")])),
      objectID: nil,
    )
  }

  static func sourceGroup(
    _ name: String,
    resources: Bool = false,
    resourceTargets: [String] = [],
    infoPlist: Bool = true,
  ) throws -> Schema.Reference {
    var children = [try folder("Sources", targets: [name])]
    if resources || !resourceTargets.isEmpty {
      children.append(try folder("Resources", targets: resourceTargets.isEmpty ? [name] : resourceTargets))
    }
    if infoPlist {
      children.append(try file("Info.plist"))
    }
    return .group(.init(
      objectID: nil,
      name: name,
      path: try .init(base: .group, path: name),
      includeInIndex: nil,
      children: children,
    ))
  }

  static func folder(_ path: String, targets: [String] = []) throws -> Schema.Reference {
    .folder(.init(
      objectID: nil,
      path: try .init(base: .group, path: path),
      targets: Set(targets.map { .init(targetName: $0) }),
      membershipExceptions: [],
      explicitFileTypes: [:],
      explicitOpaqueFolders: [],
      includeInIndex: nil,
    ))
  }

  static func file(
    _ path: String,
    base: Schema.FilePath.Base = .group,
    buildFiles: [Schema.ProjectBuildFile] = [],
  ) throws -> Schema.Reference {
    .fileReference(.init(
      objectID: nil,
      path: try .init(base: base, path: path),
      explicitFileType: nil,
      expectedSignature: nil,
      textEncoding: nil,
      lineEnding: nil,
      includeInIndex: nil,
      buildFiles: buildFiles,
    ))
  }

  static func resource(_ path: String, targets: [String]) throws -> Schema.Reference {
    try file(path, buildFiles: targets.map { buildFile($0, kind: .resources) })
  }

  static func properties(sign: Bool = false) -> Schema.BuildFileProperties {
    .init(
      platformFilters: [],
      additionalBuildFlags: nil,
      assetTags: [],
      attributes: .init(
        headerRole: nil,
        machInterfaceGeneration: nil,
        isWeak: false,
        codeSignOnCopy: sign,
        codeGeneration: .default,
        headerPreservation: sign
          ? .removeOnCopy
          : .keep,
        decompress: false,
        codeGenerationVisibility: nil,
      ),
    )
  }

  static func buildFile(_ target: String, kind: Schema.BuildPhase.Kind, name: String? = nil, sign: Bool = false) -> Schema
    .ProjectBuildFile
  {
    .init(
      objectID: nil,
      buildPhase: .named(target: .init(targetName: target), kind: kind, name: name),
      properties: properties(sign: sign),
    )
  }

  static func packageMember(_ product: String) -> Schema.SwiftPackageProductTargetMember {
    .init(
      packageProduct: .init(objectID: nil, package: nil, productName: product, productType: .other),
      buildFile: .init(objectID: nil, buildPhase: .named(kind: .frameworks, name: nil), properties: properties()),
    )
  }

  static func copyPhase(_ name: String, base: Schema.BundleBasePath, path: String = "") -> Schema.BuildPhase {
    .copy(.init(objectID: nil, name: name, bundleBasePath: base, relativePath: path, scope: .always))
  }

  static func productName(_ target: String) -> String {
    switch target {
    case "AmadoPowerHelper": target
    case "AmadoTests": "\(target).xctest"
    case "AmadoWidget": "\(target).appex"
    default: "\(target).app"
    }
  }

  static func buildableReference(_ target: String) -> String {
    """
    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(id(target).rawValue)" BuildableName="\(productName(target))" BlueprintName="\(target)" ReferencedContainer="container:Amado.xcodeproj" />
    """
  }

  static func scheme(for target: String) -> String {
    let runnableTarget =
      switch target {
      case "AmadoWidget": "AmadoiOS"
      case "AmadoTests": "Amado"
      default: target
      }
    let buildTarget = target == "AmadoWidget" ? "AmadoiOS" : target
    let runnable = "<BuildableProductRunnable runnableDebuggingMode=\"0\">\(buildableReference(runnableTarget))</BuildableProductRunnable>"
    let tests = target == "Amado" || target == "AmadoTests"
      ? """
        <TestableReference skipped="NO">\(buildableReference("AmadoTests"))</TestableReference>
        """
      : ""
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme LastUpgradeVersion="2720" version="1.3">
        <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
          <BuildActionEntries>
            <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
              \(buildableReference(buildTarget))
            </BuildActionEntry>
          </BuildActionEntries>
        </BuildAction>
        <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
          <Testables>\(tests)</Testables>
        </TestAction>
        <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">\(runnable)</LaunchAction>
        <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO">\(runnable)</ProfileAction>
        <AnalyzeAction buildConfiguration="Debug" />
        <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES" />
      </Scheme>

      """
  }
}
