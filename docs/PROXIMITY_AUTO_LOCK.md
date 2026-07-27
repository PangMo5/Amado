# Proximity Auto-lock

One tap, or just walk away. Proximity auto-lock is one of Amado's two primary
ways to lock: the Mac watches for your iPhone to leave and closes up without a
button press.

Proximity locking is performed by the Mac, so the Amado iPhone app does not
need to be open. Sign the Mac and iPhone into the same iCloud account so macOS
can recognize the iPhone across its rotating Bluetooth identifier.

## Set up

1. Open **Amado › Settings › Auto-lock** and keep the iPhone next to the Mac.
2. Select the device with the strongest signal.
3. Enable **Auto-lock when my iPhone leaves**.
4. Leave **Detection** set to **Smart** and start with **Balanced** sensitivity.
5. Wait for the nearby signal to finish learning, then walk away normally.

Smart mode is the default for new and existing configurations. Auto-lock itself
remains off until you enable it.

## Smart mode

Smart mode learns the selected iPhone's normal nearby signal instead of relying
on one fixed RSSI threshold. It combines:

- median and exponentially weighted filtering to reject brief signal spikes;
- a learned nearby baseline and an adaptive far threshold;
- signal direction and sustained confirmation before deciding you left;
- recent keyboard, pointer, and trackpad activity to avoid a borderline lock
  while the Mac is clearly in use;
- separate handling for a weakening signal and a sudden Bluetooth signal loss;
- hysteresis and a stable-return period before another lock can occur.

Recent input only delays an ambiguous, borderline decision. A sustained very
weak signal can still lock the Mac. If a previously healthy signal disappears
abruptly, Smart mode waits longer before treating the loss as departure.

Choose a sensitivity preset based on the tradeoff you want:

| Preset | Behavior |
| --- | --- |
| **Conservative** | Strongest protection against false locks; waits longer and requires a weaker signal. |
| **Balanced** | Default compromise for typical rooms and desk placement. |
| **Fast** | Reacts sooner, with less margin for noisy Bluetooth conditions. |

Use **Recalibrate nearby signal** with the iPhone nearby after moving the Mac,
changing the phone's usual position, or making a substantial change to the
room. Amado also safely reacquires the signal after Mac sleep, wake, or a
Bluetooth interruption before it can lock again.

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
  how the iPhone is carried. It estimates signal strength, not physical
  distance, so no preset can produce an exact distance boundary.
