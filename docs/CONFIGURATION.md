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
mac_id = "00000000-0000-0000-0000-000000000000"
caffeinate_mode = "off"
proximity_auto_lock = false
caffeinate_pauses_auto_lock = false
# proximity_pause_until is omitted unless auto-lock is temporarily paused
proximity_device_id = ""
proximity_device_name = ""
proximity_mode = "smart"
proximity_sensitivity = "balanced"
proximity_far_rssi = -56
proximity_grace_seconds = 2.0
proximity_smoothing = 3
remote_host = ""
```

Every key is optional. A missing key uses its default. A present key with the
wrong TOML type is rejected instead of silently replacing the last valid
configuration.

## Reference

| Key | Type | Default | Description |
| --- | --- | ---: | --- |
| `mac_id` | String | generated once | Stable UUID shared with paired clients. Do not copy another Mac's value. |
| `remote_host` | String | `""` | Public hostname of a user-operated HTTPS tunnel. Do not include `https://` or a path. Empty means LAN-only. |
| `caffeinate_mode` | String | `"off"` | Caffeinate behavior: `"off"` sleeps normally, `"lock"` stays awake and locks the login session, and `"unlocked"` stays awake without locking. Awake modes require one-time approval of Amado's Power Helper. |
| `proximity_auto_lock` | Boolean | `false` | Enables walk-away locking using the selected iPhone's Bluetooth signal. |
| `caffeinate_pauses_auto_lock` | Boolean | `false` | Pauses proximity Auto-lock while Caffeinate is set to `"unlocked"`. The setting is ignored in `"off"` and `"lock"` modes. |
| `proximity_pause_until` | Number | omitted | Unix timestamp at which a temporary auto-lock pause ends. Prefer setting this from the menu bar or Settings. The key is removed when auto-lock resumes. |
| `proximity_device_id` | String | `""` | Core Bluetooth UUID of the selected device. Prefer selecting it in Settings. |
| `proximity_device_name` | String | `""` | Cached display name used by the Settings UI. |
| `proximity_mode` | String | `"smart"` | Detection mode: `"smart"` learns the nearby signal and adapts its threshold; `"manual"` uses the three controls below. |
| `proximity_sensitivity` | String | `"balanced"` | Smart-mode preset: `"conservative"`, `"balanced"`, or `"fast"`. |
| `proximity_far_rssi` | Integer | `-56` | Manual mode only. A smoothed signal at or below this dBm value is considered far. Settings accepts `-90` through `-40`. |
| `proximity_grace_seconds` | Number | `2.0` | Manual mode only. Signal must remain far for this many seconds. The UI offers `0`, `1`, `2`, `3`, and `5`. |
| `proximity_smoothing` | Integer | `3` | Manual mode only. Number of recent RSSI samples to average. Settings accepts `1` through `8`. |

Existing configuration files that do not contain `proximity_mode` use Smart
mode automatically. Auto-lock itself remains opt-in and is not enabled by this
default. The learned nearby baseline is runtime-only: **Recalibrate nearby
signal** discards it and starts a fresh learning window without changing
`config.toml`. During normal monitoring, confirmed nearby samples can only move
the learned reference within a bounded range in a more conservative direction.
Momentarily stronger readings cannot tighten the departure threshold, and a
gradual departure cannot move the reference indefinitely.

Pausing auto-lock keeps `proximity_auto_lock` enabled but stops proximity
monitoring until `proximity_pause_until`. Amado clears an expired deadline and
starts monitoring again automatically, including after an app restart.

`caffeinate_pauses_auto_lock` is a policy-bound pause rather than a deadline.
It stops monitoring only while `caffeinate_mode = "unlocked"` and ends as soon
as Caffeinate changes to another mode.

`caffeinate_mode` is the desired policy, while the live helper status in
Settings is the source of truth for whether an awake mode's privileged
override is actually active. See [Caffeinate](CAFFEINATE.md) for
approval, locking, and safety behavior.

Setting `caffeinate_mode` to `"lock"` or `"unlocked"` by editing this file
bypasses the interactive safety confirmation, but not the operational risks or
the user's responsibility. Keep the Mac on a hard, stable, well-ventilated
surface; never run it closed in a bag, bedding, or another enclosed space.

## Reload behavior

Amado observes the file while it is running. A valid edit takes effect without
relaunching the app. Invalid TOML or a value with the wrong type is rejected,
leaving the last valid configuration active.
