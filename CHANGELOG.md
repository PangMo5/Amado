# Changelog

Notable changes to the Amado macOS app are documented here. Versions follow
semantic versioning, and the newest release appears first.

## 1.0.0 (2026-07-27)

- **Smarter walk-away locking:** Smart detection is now the default and learns
  the nearby signal, rejects brief RSSI spikes, considers departure trends and
  recent Mac activity, handles signal loss conservatively, and safely rearms
  after a stable return.
- **Manual controls preserved:** Switch to Manual detection to keep direct
  control over the RSSI threshold, delay, and smoothing window.
- **Calibration and diagnostics:** Choose Conservative, Balanced, or Fast
  sensitivity, recalibrate the nearby baseline, and see clearer detection
  status in Settings.
- **Verified lock status:** The iPhone app can show whether each paired Mac is
  locked, and iPhone, Widget, Control Center, and Apple Watch actions now report
  whether the Mac was already locked, became locked, or could not confirm the
  requested transition. Control Center shows native in-progress/result status,
  and the Home Screen widget updates its tile after each action or refreshes the
  Mac's current status on demand.
- **Authenticated responses:** LAN and optional remote commands now return
  HMAC-signed, fresh responses bound to the original request nonce.
- **Companion compatibility:** Update the iPhone and Apple Watch companion to
  1.0.0 to receive verified Mac status and action feedback.

## 0.1.1 (2026-07-21)

- **Fixed:** Prevented the macOS app from crashing at launch in optimized
  release builds.

## 0.1.0 (2026-07-16)

- **One-tap lock:** Lock your Mac from iPhone, Apple Watch, a Home Screen widget,
  or Control Center.
- **Walk-away auto-lock:** Lock your Mac automatically using Bluetooth proximity,
  with configurable threshold, grace period, and smoothing.
- **Secure delivery:** Pair by QR, connect directly over Bonjour, or use your own
  HTTPS tunnel when away.
