# Proximity Auto-lock

Proximity Auto-lock is Amado's no-tap path: the Mac watches for your selected phone to
leave and closes up without a button press. It remains independent of the
local Caffeinate policy that controls lid-close sleep.

Proximity locking is performed by the Mac, so no companion phone app needs to
be open. iPhone uses native Continuity advertising: sign the Mac and iPhone
into the same iCloud account so macOS can recognize the phone across its
rotating Bluetooth identifier. Android and other devices use an experimental
system-paired Bluetooth Classic connection when macOS exposes usable RSSI.

## Set up

1. For Android or another Classic device, pair it in **System Settings › Bluetooth** first.
2. Open **Amado › Settings › Auto-lock** and keep the phone next to the Mac.
3. Select the matching **Nearby BLE** or **Paired Bluetooth · Experimental** device.
4. Enable **Auto-lock when my phone leaves**.
5. Confirm that Status reaches **Nearby** with a negative dBm value. If it says
   signal strength is unavailable, Auto-lock remains inactive for that device.
6. Leave **Detection** set to **Smart** and start with **Balanced** sensitivity.
7. Wait for the nearby signal to finish learning, then walk away normally.

Smart mode is the default for new and existing configurations. Auto-lock itself
remains off until you enable it.

## Smart mode

Smart mode learns the selected phone's normal nearby signal instead of relying
on one fixed RSSI threshold. It combines:

- a fast three-sample median and a stable exponentially weighted filter;
- a conservative rolling nearby baseline and an adaptive far threshold;
- weak-signal consistency, signal direction, and preset confirmation timing;
- separate handling for a weakening signal and a sudden Bluetooth signal loss;
- hysteresis and a stable-return period before another lock can occur.

Momentarily stronger readings cannot tighten the nearby reference. While the
phone is independently confirmed nearby, the rolling reference may only move
within a bounded range in the more conservative direction. The bound prevents a
slow departure from being learned indefinitely. A recalibration is required to
intentionally adopt a stronger normal placement.

When the fast and stable filters agree that the signal is decisively weak,
Smart mode locks without waiting for the full confirmation period. Fast
readings can raise confidence, but ordinary fades must also cross the stable
departure threshold and remain there for the selected preset's confirmation
time. Keyboard, pointer, and trackpad activity is never treated as proof that
the owner is present, so another person using the Mac cannot delay auto-lock or
teach a departing signal as the new nearby baseline. On the Continuity path, if
a previously healthy signal disappears abruptly, Smart mode waits longer before
treating the loss as departure, but input activity cannot extend that cap.
Classic uses valid negative RSSI for normal departure decisions. Once nearby
samples have armed detection, the current authenticated link's actual
disconnect enters the same conservative signal-loss confirmation instead of
discarding the state. An invalid RSSI sample alone, Bluetooth-off, Mac
sleep/wake, configuration changes, and a connection that never produced usable
RSSI remain fail-open.

Choose a sensitivity preset based on the tradeoff you want:

| Preset | Behavior |
| --- | --- |
| **Conservative** | Strongest protection against false locks; waits longer and requires a weaker signal. |
| **Balanced** | Default compromise for typical rooms and desk placement. |
| **Fast** | Reacts sooner, with less margin for noisy Bluetooth conditions. |

Use **Recalibrate nearby signal** with the selected phone nearby after moving the Mac,
changing the phone's usual position, or making a substantial change to the
room. Amado also safely reacquires the signal after Mac sleep, wake, or a
Bluetooth interruption before it can lock again.

## Temporary pause

Use **Pause Auto-lock** in the menu bar for a 15-minute, 30-minute, one-hour,
two-hour, or four-hour pause. **Settings › Auto-lock** also lets you choose an
exact resume date and time.

A pause stops the Bluetooth monitor rather than merely ignoring its final lock
event. Auto-lock remains enabled, the deadline is saved locally, and monitoring
starts again automatically at that time even if Amado restarts. Choose
**Resume Auto-lock** to end the pause early. Turning auto-lock off clears an
active pause.

Selecting Caffeinate's **Stay awake, keep unlocked** policy asks whether
Auto-lock should pause for the lifetime of that policy. This policy-bound pause
also stops the Bluetooth monitor and ends automatically when Caffeinate changes
to Lock or Off. If Auto-lock remains enabled instead, a departure locks the
session but does not put the caffeinated Mac to sleep.

## Manual mode

Choose **Manual** when you want direct control over the original RSSI behavior.
Manual mode uses:

- **Far threshold:** a lower (more negative) value requires a weaker signal
  before locking;
- **Delay:** how long the smoothed signal must stay beyond the threshold;
- **Smoothing:** how many recent RSSI readings are averaged.

For example, if the nearby reading is about `-48 dBm`, `-58 dBm` is a reasonable
initial threshold. Fewer samples react faster but are noisier; more samples are
steadier but slower.

The underlying `proximity_*` keys are documented in the
[configuration reference](CONFIGURATION.md).

## Troubleshooting

- In Smart mode, recalibrate in the room and phone position you normally use.
- Try **Conservative** if the Mac locks while you are still nearby, or **Fast**
  if confirmed departures are consistently too slow.
- In Manual mode, move `proximity_far_rssi` toward `-90` to require a weaker
  signal, or toward `-40` to lock sooner.
- In Manual mode, increase delay or smoothing for unstable readings. Reduce
  them for a faster response.
- RSSI is affected by walls, furniture, body position, radio interference, and
  how the phone is carried. It estimates signal strength, not physical
  distance, so no preset can produce an exact distance boundary.
- A paired device can appear in the picker even while disconnected. Android
  support depends on the phone, Bluetooth controller, and OS. If Status remains
  **Connected, but signal strength is unavailable**, macOS is returning `0` or
  `+127` instead of usable RSSI; Amado intentionally does not lock from that.
- In Smart mode, an abrupt loss from a strong nearby signal can take up to 90
  seconds to confirm; loss after an already weakening signal can confirm at the
  first 30-second freshness check. Connection failure before arming, unpairing,
  Bluetooth interruption, Mac sleep, and wake reset the decision state and
  remain fail-open. Test screen-off, idle, sleep/wake, and several real
  walk-aways before relying on this path.
