<p align="center">
  <img src="Amado/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Amado app icon" />
</p>

<h1 align="center">Amado</h1>

<p align="center">
  Lock your Mac from iPhone, Apple Watch, a widget, or Control Center.
</p>

<p align="center">
  <a href="https://github.com/PangMo5/Amado/releases"><img src="https://img.shields.io/github/v/release/PangMo5/Amado?display_name=tag&include_prereleases&sort=semver" alt="GitHub release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MPL--2.0-blue.svg" alt="MPL-2.0 license" /></a>
  <img src="https://img.shields.io/badge/Swift-6.0-orange.svg" alt="Swift 6" />
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg" alt="macOS 15 or later" />
  <img src="https://img.shields.io/badge/iOS-18%2B-black.svg" alt="iOS 18 or later" />
  <img src="https://img.shields.io/badge/watchOS-11%2B-black.svg" alt="watchOS 11 or later" />
</p>

*Amado* (雨戸) are the sliding shutters that close a Japanese house. One tap
closes your Mac the same way: the menu-bar agent immediately returns it to the
login window.

## Features

- **Everywhere you need it** — lock from the iPhone app, Apple Watch, a Home
  Screen widget, or Control Center.
- **Fast on your LAN** — Bonjour discovery and a direct authenticated command,
  with no account or hosted service.
- **Remote when you choose** — bring your own HTTPS tunnel; Amado never proxies
  commands through a service operated by this project.
- **Walk-away auto-lock** — the Mac can use your nearby iPhone's Bluetooth
  signal as a proximity trigger.
- **Authenticated pairing** — QR pairing provisions a 256-bit secret used for
  HMAC-SHA256 authentication, timestamp checks, and replay protection.

## How it works

```text
Apple Watch ── WatchConnectivity ──▶ iPhone ─┬─ Bonjour + TCP ───────▶ Mac
Widget / Control Center / iPhone app ────────┤
                                             └─ HTTPS tunnel ───────▶ Mac
```

The iPhone client tries the local network first and uses the paired Mac's
optional tunnel only when LAN delivery is unavailable. The tunnel forwards to a
loopback-only HTTP listener on `127.0.0.1:51521`.

See [Security](docs/SECURITY.md) for the trust model and protocol boundaries.

## Install

Install the macOS agent with Homebrew:

```sh
brew install --cask PangMo5/tap/amado
```

Or download it from [GitHub Releases](https://github.com/PangMo5/Amado/releases).
Sparkle checks for updates in the background, and **Check for Updates…** is
available from the menu-bar item. The iPhone, widget, and Watch clients
currently build from source with the same signing team.

1. Launch Amado on the Mac and enable **Launch at Login** if wanted.
2. Open **Settings › Pairing › Reveal pairing code**.
3. In the iPhone app, scan the QR code.
4. Use the app, widget, Control Center control, or Watch app to lock the Mac.

## Configuration

Most settings are available in the Mac app. Non-sensitive values also live at
`~/.config/amado/config.toml` (or `$XDG_CONFIG_HOME/amado/config.toml`) and are
reloaded when the file changes. Pairing secrets stay in Keychain.

| Setting | Default | Purpose |
| --- | ---: | --- |
| `remote_host` | `""` | Public hostname of your HTTPS tunnel; empty is LAN-only |
| `proximity_auto_lock` | `false` | Lock when the selected iPhone leaves |
| `proximity_far_rssi` | `-56` | Far threshold in dBm |
| `proximity_grace_seconds` | `2` | Time beyond the threshold before locking |
| `proximity_smoothing` | `3` | Number of RSSI samples to average |

The complete schema, proximity tuning, and Cloudflare Tunnel, Tailscale Funnel,
and ngrok recipes are in [Configuration](docs/CONFIGURATION.md).

## Development

```sh
mise install        # install pinned Tuist and SwiftFormat versions
make bootstrap      # install dependencies and generate Amado.xcworkspace
make build          # build the macOS agent
make build-ios      # build the iPhone app, widget, and Watch app
make run            # build and launch the distinct Amado Dev app
make test           # run AmadoKit tests on macOS
make format         # format and lint Swift sources
```

Set your signing team in the git-ignored `.mise.local.toml`:

```toml
[env]
TUIST_DEVELOPMENT_TEAM = "YOUR_TEAM_ID"
```

Tagged, signed releases are documented in [Releasing](docs/RELEASING.md).

### Targets

| Target | Product | Platform |
| --- | --- | --- |
| `Amado` | Menu-bar app | macOS 15+ |
| `AmadoiOS` | App | iOS 18+ |
| `AmadoWatch` | Companion app | watchOS 11+ |
| `AmadoWidget` | Widget and Control extension | iOS 18+ |
| `AmadoKit` | Shared framework | macOS, iOS, watchOS |
| `AmadoTests` | Swift Testing suite | macOS |

Amado uses Tuist, The Composable Architecture, Sharing, Hummingbird, Sparkle,
WidgetKit, App Intents, Swift Testing, and strict Swift 6 concurrency.

## License

[Mozilla Public License 2.0](LICENSE). MPL-2.0 is file-level copyleft: changes
to MPL-covered files remain under MPL-2.0, while new files may use another
compatible license. Executable distribution is allowed as long as recipients
can access the covered source.
