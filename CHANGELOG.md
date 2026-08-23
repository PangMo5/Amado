# Changelog

Notable changes to the Amado macOS app are documented here. Versions follow semantic versioning, and the newest release appears first.

## Unreleased

## 2.0.3 (2026-08-24)

- Added one context-sensitive confirmation before Caffeinate can keep the login session unlocked. It combines operational and security warnings when needed, exposes Auto-lock keep/pause choices as buttons in the same dialog, and keeps persistent warnings about physical access, existing remote-control software, and exposed session data.
- The menu-bar pause badge now uses a clock only for timed pauses and a pause symbol when Auto-lock is paused for the duration of Caffeinate's unlocked policy.

## 2.0.2 (2026-08-22)

- Fixed a Power Helper update loop caused by re-registering a daemon before macOS finished removing its previous registration.
- Debug builds now use a separate Power Helper identity so they cannot take ownership of the helper installed by a release build.
- A failed helper installation can be retried directly without quitting and reopening Amado.
- The first-install action remains available when macOS has not created its background-task record yet but the signed Power Helper is present in the app bundle.

## 2.0.1 (2026-08-22)

- **Explicit Power Helper lifecycle:** Caffeinate now shows whether its helper is missing, awaiting approval, installed, or outdated. Installation and updates happen only from their dedicated buttons; removal is disabled when no helper is registered.
- **Fixed Power Helper updates:** Amado verifies the registered helper's version and build and refuses to report Caffeinate as active until the current bundled helper answers.
- **First-class Caffeinate settings:** Caffeinate now has its own Settings pane with separate helper-installation and sleep-override status, direct access to Login Items & Extensions, and an explicit removal action that restores normal lid-close sleep.
- **Consistent unavailable state:** The Caffeinate controls stay disabled until the current Power Helper is ready. Missing, unapproved, outdated, or failed helpers reset a stale awake policy to normal lid-close sleep instead of accepting a selection that cannot take effect.
- **License boundary:** The macOS app, Power Helper, tooling, documentation, and website are now AGPL-3.0-only. The iPhone, Apple Watch, Widget, and shared `AmadoKit` sources remain MPL-2.0.

## 2.0.0 (2026-08-22)

- **Caffeinate:** Keep a MacBook running after its lid closes with an explicit Off/Lock/Unlocked policy. The default awake policy locks the login session and sleeps the displays; the unlocked policy can pause proximity Auto-lock for as long as it remains selected.
- **Narrow, fail-safe Power Helper:** The administrator-approved helper accepts only sleep-override leases from the expected, same-team Amado app. Disconnecting, quitting, crashing, or restarting the helper restores normal sleep instead of leaving a global override behind.
- **Visible safety state:** Menu-bar icon layers independently show Auto-lock, Caffeinate's lock policy, and an active pause. Settings and the menu expose the saved policy separately from the live helper state, and awake modes retain heat, ventilation, battery, and physical-security warnings.
- **Self-healing agent:** Listener, Bluetooth, login-item, persistence, and screen-lock failures now surface in the menu bar, Settings, and local notifications. Recoverable services retry automatically instead of leaving the agent silently unavailable.

## 1.0.3 (2026-08-03)

- **Fixed the agent quitting on every command:** Answering a lock, status, pairing, or unpair request terminated the menu bar agent in optimized release builds, so the iPhone reported a failure and the Mac stopped responding until it was launched again. The one-shot response channel no longer races a timeout task to hand an answer back to the transport.
- **Stable device identities:** The Mac now shares a stable UUID separately from the name supplied by macOS, keeping pairings linked without coupling identity to Bonjour discovery.
- **Paired iPhone management:** See paired iPhones by their stable UUID-derived labels and remove individual installations from Mac Settings.
- **Scheduled auto-lock pause:** Pause proximity auto-lock for a preset duration or until an exact time without disabling the feature.

## 1.0.2 (2026-07-27)

- **Fixed nearby false locks:** Smart detection no longer lets momentarily stronger Bluetooth readings tighten the learned nearby reference. Confirmed nearby samples now maintain a bounded, conservative rolling baseline that can only make the departure threshold safer without learning a gradual departure as nearby.
- **Stable departure confirmation:** Fast readings still make a clear departure react promptly, but the stable filter must also approach or cross the learned threshold before a normal fade or signal loss can trigger a lock.

## 1.0.1 (2026-07-27)

- **Safer, faster Smart auto-lock:** Smart detection now combines fast and stable signal filters, weak-signal consistency, departure trend, and adaptive confirmation. Clear departures lock promptly while brief RSSI spikes remain ignored.
- **Owner-presence hardening:** Keyboard, pointer, and trackpad activity can no longer delay a confirmed departure lock or influence baseline learning, so activity by another person cannot keep the Mac unlocked after the owner leaves.

## 1.0.0 (2026-07-27)

- **Smarter walk-away locking:** Smart detection is now the default and learns the nearby signal, rejects brief RSSI spikes, considers departure trends and recent Mac activity, handles signal loss conservatively, and safely rearms after a stable return.
- **Manual controls preserved:** Switch to Manual detection to keep direct control over the RSSI threshold, delay, and smoothing window.
- **Calibration and diagnostics:** Choose Conservative, Balanced, or Fast sensitivity, recalibrate the nearby baseline, and see clearer detection status in Settings.
- **Verified lock status:** The iPhone app can show whether each paired Mac is locked, and iPhone, Widget, Control Center, and Apple Watch actions now report whether the Mac was already locked, became locked, or could not confirm the requested transition. Control Center shows native in-progress/result status, and the Home Screen widget updates its tile after each action or refreshes the Mac's current status on demand.
- **Authenticated responses:** LAN and optional remote commands now return HMAC-signed, fresh responses bound to the original request nonce.
- **Companion compatibility:** Update the iPhone and Apple Watch companion to 1.0.0 to receive verified Mac status and action feedback.

## 0.1.1 (2026-07-21)

- **Fixed:** Prevented the macOS app from crashing at launch in optimized release builds.

## 0.1.0 (2026-07-16)

- **One-tap lock:** Lock your Mac from iPhone, Apple Watch, a Home Screen widget, or Control Center.
- **Walk-away auto-lock:** Lock your Mac automatically using Bluetooth proximity, with configurable threshold, grace period, and smoothing.
- **Secure delivery:** Pair by QR, connect directly over Bonjour, or use your own HTTPS tunnel when away.
