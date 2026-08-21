// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI

// MARK: - AmadoApp

@main
struct AmadoApp: App {

  // MARK: Internal

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(store: store)
    } label: {
      // The label view is always mounted in the menu bar, so its `.task` is
      // where we start the listener at launch (the agent is `LSUIElement` and
      // has no window to hang a lifecycle on).
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.menu)

    // Opened on demand from the menu ("Show pairing code…").
    Window("Amado", id: "pairing") {
      PairingView(store: store)
        .regularWhileOpen()
    }
    .windowResizability(.contentSize)

    Window("Amado Settings", id: "settings") {
      SettingsView(store: store)
        .regularWhileOpen()
    }
    .windowResizability(.contentSize)
  }

  // MARK: Private

  @State private var store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

}

// MARK: - MenuBarLabel

private struct MenuBarLabel: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    // MenuBarExtra retains only one status-item image. Precompose independent
    // layers so every symbol keeps one meaning: auto-lock, Caffeinate policy,
    // pause, and attention.
    Image(nsImage: statusImage)
      .accessibilityLabel(accessibilityLabel)
      .task { await store.send(.task).finish() }
  }

  // MARK: Private

  private var statusImage: NSImage {
    MenuBarStatusImages.make(for: store.menuBarIndicator)
  }

  private var accessibilityLabel: String {
    let indicator = store.menuBarIndicator
    var components = [
      "Amado",
      indicator.isAutoLockEnabled ? "auto-lock on" : "auto-lock off",
    ]
    if let policy = indicator.closedLidPolicy {
      components.append("Caffeinate active")
      components.append(policy.statusDescription)
    }
    if let pause = store.activeAutoLockPause {
      switch pause {
      case .until(let deadline):
        components.append(
          "auto-lock paused until \(deadline.formatted(date: .omitted, time: .shortened))"
        )

      case .whileCaffeinating:
        components.append("auto-lock paused while Caffeinate keeps unlocked")
      }
    }
    if let issue = store.issues.first {
      components.append(issue.title)
    } else if !store.isListening {
      components.append("starting")
    }
    return components.joined(separator: "; ")
  }

}

// MARK: - MenuBarStatusImages

@MainActor
private enum MenuBarStatusImages {

  // MARK: Internal

  static func make(for state: MenuBarIndicatorState) -> NSImage {
    if let image = cache[state] {
      return image
    }

    let image = compose(
      primary: configuredImage(
        state.isAutoLockEnabled ? .lockFill : .lockOpenFill,
        configuration: primaryConfiguration,
      ),
      closedLidPolicy: state.closedLidPolicy,
      isPaused: state.isAutoLockPaused,
      needsAttention: state.needsAttention,
    )
    cache[state] = image
    return image
  }

  // MARK: Private

  private static let canvasHeight: CGFloat = 18
  private static let badgeGap: CGFloat = -0.5
  private static let primaryConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
  private static let primaryBadgeAnchorWidth = configuredImage(
    .lockFill,
    configuration: primaryConfiguration,
  ).size.width
  private static let accessoryConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .medium)
  private static let detailConfiguration = NSImage.SymbolConfiguration(pointSize: 5.5, weight: .medium)
  private static let attentionConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .medium)
  private static var cache = [MenuBarIndicatorState: NSImage]()

  private static func compose(
    primary: NSImage,
    closedLidPolicy: ClosedLidMode.AwakePolicy?,
    isPaused: Bool,
    needsAttention: Bool,
  ) -> NSImage {
    let coffee = closedLidPolicy.map { _ in
      configuredImage(.cupAndSaucerFill, configuration: accessoryConfiguration)
    }
    let policyLock = closedLidPolicy.map {
      configuredImage(
        $0 == .lockOnClose ? .lockFill : .lockOpenFill,
        configuration: detailConfiguration,
      )
    }
    let clock = isPaused
      ? configuredImage(.clockFill, configuration: detailConfiguration)
      : nil
    let attention = needsAttention
      ? configuredImage(.exclamationmarkTriangleFill, configuration: attentionConfiguration)
      : nil

    let leadingInset = attention.map { $0.size.width * 0.55 } ?? 0
    let primaryOrigin = NSPoint(
      x: leadingInset,
      y: (canvasHeight - primary.size.height) / 2,
    )
    let primaryImageMaxX = primaryOrigin.x + primary.size.width
    let primaryBadgeAnchorMaxX = primaryOrigin.x + primaryBadgeAnchorWidth

    let closedLidOverflow: CGFloat =
      if let coffee, let policyLock {
        coffee.size.width * 0.45 + badgeGap + policyLock.size.width
      } else {
        0
      }
    let clockOverflow = clock.map { $0.size.width * 0.28 } ?? 0
    let canvasWidth = ceil(
      max(
        primaryImageMaxX,
        primaryBadgeAnchorMaxX + max(closedLidOverflow, clockOverflow),
      )
    )
    let canvasSize = NSSize(width: canvasWidth, height: canvasHeight)

    let image = NSImage(size: canvasSize, flipped: false) { canvas in
      primary.draw(
        at: primaryOrigin,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
      )

      if let coffee, let policyLock {
        let coffeeOrigin = NSPoint(
          x: primaryBadgeAnchorMaxX - coffee.size.width * 0.55,
          y: 0.25,
        )
        drawBadge(coffee, at: coffeeOrigin, haloPadding: 0.55)
        drawBadge(
          policyLock,
          at: NSPoint(
            x: coffeeOrigin.x + coffee.size.width + badgeGap,
            y: coffeeOrigin.y + (coffee.size.height - policyLock.size.height) / 2,
          ),
          clearsBackground: false,
        )
      }

      if let clock {
        drawBadge(
          clock,
          at: NSPoint(
            x: primaryBadgeAnchorMaxX - clock.size.width * 0.72,
            y: canvas.height - clock.size.height,
          ),
          haloPadding: 0.5,
        )
      }

      if let attention {
        drawBadge(
          attention,
          at: NSPoint(
            x: 0,
            y: canvas.height - attention.size.height,
          ),
        )
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func drawBadge(
    _ image: NSImage,
    at origin: NSPoint,
    haloPadding: CGFloat = 0.7,
    clearsBackground: Bool = true,
  ) {
    let bounds = NSRect(origin: origin, size: image.size)
      .insetBy(dx: -haloPadding, dy: -haloPadding)
    if clearsBackground, let context = NSGraphicsContext.current?.cgContext {
      context.saveGState()
      context.setBlendMode(.clear)
      context.fillEllipse(in: bounds)
      context.restoreGState()
    }
    image.draw(
      at: origin,
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
    )
  }

  private static func configuredImage(
    _ symbol: SFSymbol,
    configuration: NSImage.SymbolConfiguration,
  ) -> NSImage {
    guard
      let image = NSImage(
        systemSymbolName: symbol.rawValue,
        accessibilityDescription: nil,
      )?.withSymbolConfiguration(configuration)
    else {
      preconditionFailure("Missing bundled SF Symbol: \(symbol.rawValue)")
    }
    return image
  }

}

// MARK: - Regular-while-open

extension View {
  /// Promote the `LSUIElement` agent to a regular app (Dock icon, normal
  /// front-most focus, standard window chrome) while this window is open, and
  /// drop back to accessory once the last window closes. Mirrors Tatami.
  fileprivate func regularWhileOpen() -> some View {
    onAppear { WindowActivation.opened() }
      .onDisappear { WindowActivation.closed() }
  }
}

// MARK: - WindowActivation

/// Reference-counts open windows so several (pairing + settings) can be open at
/// once without one closing prematurely dropping the app back to accessory.
@MainActor
private enum WindowActivation {
  static var openCount = 0

  static func opened() {
    openCount += 1
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  static func closed() {
    openCount = max(0, openCount - 1)
    if openCount == 0 {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
