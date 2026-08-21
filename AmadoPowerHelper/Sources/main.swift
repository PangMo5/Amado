// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

let delegate = PowerHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: PowerHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// launchd uses SIGTERM when the user disables or upgrades the helper. Handle
// that graceful path so the global sleep override is not left behind. A hard
// crash is covered by launchd restarting the helper, whose initializer also
// restores normal sleep before accepting connections.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM)
terminationSource.setEventHandler {
  Task {
    await delegate.shutDown()
    exit(EXIT_SUCCESS)
  }
}

terminationSource.resume()

dispatchMain()
