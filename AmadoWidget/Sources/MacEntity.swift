// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MPL-2.0

import AmadoKit
import AppIntents
import Foundation

// MARK: - MacOptionsProvider

/// Supplies paired Macs as named UUID options without relying on AppEntity
/// registration when WidgetKit restores a saved configuration.
struct MacOptionsProvider: DynamicOptionsProvider {
  func results() async throws -> ItemCollection<String> {
    let items = PairedMacsStore.load().map { mac in
      IntentItem(mac.id.uuidString, title: "\(mac.displayName)")
    }
    return ItemCollection(sections: [IntentItemSection(items: items)])
  }
}
