# Configuration

Amado's Mac agent exposes its everyday settings in **Amado › Settings** and
stores the non-sensitive subset in a small TOML file. Edit the UI or the file;
changes to the file are observed while the app is running.

## File location

The default path is:

```text
~/.config/amado/config.toml
```

If `XDG_CONFIG_HOME` is set, Amado uses:

```text
$XDG_CONFIG_HOME/amado/config.toml
```

The pairing secret is intentionally absent. It is an authentication key and is
stored in the macOS Keychain instead. Launch at Login is managed by macOS
Service Management and is not part of this file either.

## Complete example

```toml
proximity_auto_lock = false
proximity_device_id = ""
proximity_device_name = ""
proximity_far_rssi = -56
proximity_grace_seconds = 2.0
proximity_smoothing = 3
remote_host = ""
```

Every key is optional. A missing key uses its default; a present key with the
wrong TOML type is rejected instead of silently replacing the last valid
configuration.

## Reference

| Key | Type | Default | Description |
| --- | --- | ---: | --- |
| `remote_host` | String | `""` | Public hostname of a user-operated HTTPS tunnel. Do not include `https://` or a path. Empty means LAN-only. |
| `proximity_auto_lock` | Boolean | `false` | Enables walk-away locking using the selected iPhone's Bluetooth signal. |
| `proximity_device_id` | String | `""` | Core Bluetooth UUID of the selected device. Prefer selecting it in Settings. |
| `proximity_device_name` | String | `""` | Cached display name used by the Settings UI. |
| `proximity_far_rssi` | Integer | `-56` | A smoothed signal at or below this dBm value is considered far. Settings accepts `-90` through `-40`. |
| `proximity_grace_seconds` | Number | `2.0` | Signal must remain far for this many seconds. The UI offers `0`, `1`, `2`, `3`, and `5`. |
| `proximity_smoothing` | Integer | `3` | Number of recent RSSI samples to average. Settings accepts `1` through `8`. |

## Pairing

1. Open **Amado › Settings › Pairing** on the Mac.
2. Choose **Reveal pairing code**.
3. Scan the QR code in the iPhone app.
4. Hide the code when finished.

The QR includes the Mac name, pairing secret, and current `remote_host`. If you
change the remote host, pair again so the client receives it. Anyone who obtains
the pairing payload can send valid lock commands, so treat it like a password.

**Regenerate pairing secret** invalidates every existing client. Pair the iPhone
again after regenerating; the Watch, widget, and Control Center use the iPhone's
updated paired-Mac data.

## Remote access

Remote access is optional. Amado listens only on `127.0.0.1:51521`; you operate
an HTTPS tunnel that maps a public hostname to that loopback port. Enter only
the hostname in **Settings › Remote access**, then choose **Test connection**.

Amado always tries direct LAN delivery first. It falls back to the tunnel only
when the Mac cannot be reached locally.

### Cloudflare Tunnel

Use this when you own a domain managed by Cloudflare and want a stable host.

```sh
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create amado
cloudflared tunnel route dns amado amado.example.com
```

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: amado
credentials-file: /Users/you/.cloudflared/TUNNEL-UUID.json
ingress:
  - hostname: amado.example.com
    service: http://127.0.0.1:51521
  - service: http_status:404
```

Run it with:

```sh
cloudflared tunnel run amado
```

Set `remote_host = "amado.example.com"`.

### Tailscale Funnel

Use this when you prefer a `ts.net` hostname and do not need your own domain.
Funnel must be enabled for the tailnet.

```sh
brew install tailscale
tailscale up
tailscale funnel --bg 51521
tailscale funnel status
```

Set `remote_host` to the reported hostname, for example
`"my-mac.example-tailnet.ts.net"`.

### ngrok

Use a static ngrok domain so the paired hostname does not change between runs.

```sh
brew install ngrok
ngrok config add-authtoken YOUR_TOKEN
ngrok http --domain=your-static.ngrok-free.app 51521
```

Set `remote_host = "your-static.ngrok-free.app"`.

> The tunnel publishes a lock endpoint to the internet. HTTPS protects the
> connection, while Amado's HMAC authentication protects the command. Keep the
> pairing secret private and use a tunnel provider you trust.

## Proximity auto-lock

Proximity locking is performed by the Mac; the Amado iPhone app does not need
to be open. Sign the Mac and iPhone into the same iCloud account so macOS can
recognize the iPhone across its rotating Bluetooth identifier.

1. Open **Settings › Auto-lock** and keep the iPhone next to the Mac.
2. Select the device with the strongest signal.
3. Enable **Auto-lock when my iPhone leaves**.
4. Observe the nearby RSSI while seated, then set the far threshold a few dBm
   weaker (more negative). If seated is about `-48 dBm`, start near `-58 dBm`.
5. Walk away and tune the threshold, delay, and smoothing for the room.

Lower thresholds require the signal to become weaker before locking. Fewer
samples react faster but are noisier; more samples are steadier but slower. A
grace period prevents a brief Bluetooth dip from locking the Mac.

## Troubleshooting

### The iPhone cannot find the Mac on the LAN

- Confirm both devices are on the same local network.
- Allow Local Network access for Amado in system privacy settings.
- Confirm the Mac menu-bar agent reports **Listening**.
- Guest Wi-Fi and client isolation can block Bonjour and direct device traffic.

### The remote test fails

- Confirm the tunnel forwards to `http://127.0.0.1:51521` on the Mac.
- Enter only a hostname, without `https://`, a port, or a path.
- Verify the tunnel process is running before using **Test connection**.
- Pair again after changing the hostname.

### Proximity locks too early or too late

- Recalibrate in the room where the Mac is normally used.
- Move `proximity_far_rssi` toward `-90` to require a weaker signal, or toward
  `-40` to lock sooner.
- Increase grace or smoothing for unstable readings; reduce them for a faster
  response.
