# Proximity Auto-lock

One tap—or just walk away. Proximity auto-lock is one of Amado's two primary
ways to lock: the Mac watches for your iPhone to leave and closes up without a
button press.

Proximity locking is performed by the Mac, so the Amado iPhone app does not
need to be open. Sign the Mac and iPhone into the same iCloud account so macOS
can recognize the iPhone across its rotating Bluetooth identifier.

## Set up and calibrate

1. Open **Amado › Settings › Auto-lock** and keep the iPhone next to the Mac.
2. Select the device with the strongest signal.
3. Enable **Auto-lock when my iPhone leaves**.
4. Observe the nearby RSSI while seated, then set the far threshold a few dBm
   weaker (more negative). If seated is about `-48 dBm`, start near `-58 dBm`.
5. Walk away and tune the threshold, delay, and smoothing for the room.

Lower thresholds require the signal to become weaker before locking. Fewer
samples react faster but are noisier; more samples are steadier but slower. A
grace period prevents a brief Bluetooth dip from locking the Mac.

The underlying `proximity_*` keys are documented in the
[configuration reference](CONFIGURATION.md).

## Troubleshooting

- Recalibrate in the room where the Mac is normally used.
- Move `proximity_far_rssi` toward `-90` to require a weaker signal, or toward
  `-40` to lock sooner.
- Increase grace or smoothing for unstable readings; reduce them for a faster
  response.
