# iOS Changelog

Notable changes to the Amado iPhone, Apple Watch, widget, and Control Center
clients are documented here. Versions follow semantic versioning, and the
newest release appears first.

## 1.0.0 (2026-07-27)

- **Live Mac status:** See whether each paired Mac is locked or unlocked and
  pull to refresh its current state.
- **Verified lock feedback:** Lock actions now report whether the Mac was
  already locked, became locked, or could not confirm the requested transition.
- **Native quick-access feedback:** Control Center reports progress and the
  result, while the Home Screen widget updates after every action and includes
  a refresh button for the Mac's current status.
- **Apple Watch confirmation:** Watch actions now show the authenticated result
  returned by the Mac.
- **Companion compatibility:** Update Amado on the Mac to 1.0.0 to receive
  verified status and action feedback.

## 0.1.0 (2026-07-16)

- **One-tap lock:** Lock your Mac from the iPhone app, Apple Watch, a Home
  Screen widget, or Control Center.
- **Walk-away auto-lock:** Use Bluetooth proximity to lock your Mac
  automatically when you leave with your iPhone.
- **Secure delivery:** Pair by QR, connect directly over Bonjour, or use your
  own HTTPS tunnel when away.
