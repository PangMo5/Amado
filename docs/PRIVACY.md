# Privacy

Last updated: July 17, 2026

Amado does not collect personal data, use analytics or advertising SDKs, track
you across apps or websites, or operate a hosted relay service.

## Data stored on your devices

- **Pairing data:** The Mac stores the pairing secret in Keychain. The iPhone
  stores paired Mac details in its App Group container so the app, widget,
  Control Center control, and Apple Watch app can use the same Macs.
- **Configuration:** The Mac stores non-sensitive settings locally in
  `config.toml`.
- **Developer access:** PangMo5 does not receive this data.

Removing a paired Mac from the iPhone app deletes its locally stored pairing
data. Regenerating the pairing secret on the Mac invalidates the previous
secret.

## Network communication

- **Local network:** Amado uses Bonjour and a direct connection between your
  iPhone and Mac on the same local network.
- **Optional remote access:** You may configure an HTTPS tunnel that you choose
  and operate. Traffic then passes through that provider under its own privacy
  policy. Amado does not provide or operate the tunnel.
- **No Amado account:** There is no Amado account, cloud database, or developer
  server receiving lock commands.

## Bluetooth proximity

Bluetooth proximity auto-lock runs on the Mac. The Mac observes the selected
iPhone's Bluetooth signal to decide when to lock. Amado does not use location
services, collect a location history, or send Bluetooth observations to
PangMo5.

## Camera

The iPhone app uses the camera only while you scan the pairing QR code shown on
your Mac. Amado does not save or upload camera images.

## Apple services

Apple may process App Store downloads, TestFlight distribution, and related
diagnostics according to Apple's own privacy policies. That processing is
separate from Amado.

## Contact

For privacy questions, open a
[GitHub issue](https://github.com/PangMo5/Amado/issues). For a security concern,
use [GitHub private vulnerability reporting](https://github.com/PangMo5/Amado/security/advisories/new).
