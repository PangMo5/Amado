# config.toml Reference

Amado's Mac agent persists its non-sensitive settings in a TOML file. Every
setting in this document can also be changed in **Amado › Settings**.

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

## Reload behavior

Amado observes the file while it is running. A valid edit takes effect without
relaunching the app. Invalid TOML or a value with the wrong type is rejected,
leaving the last valid configuration active.
