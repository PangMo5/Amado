# Pairing

Pairing transfers an authenticated lock-and-status capability from the Mac to
the iPhone. The Apple Watch, widget, and Control Center use the iPhone's
paired-Mac data. This powers Amado's one-tap path and its verified result.
Walk-away auto-lock is configured separately on the Mac, and neither path can
unlock the Mac.

## Pair an iPhone

1. Open **Amado › Settings › Pairing** on the Mac.
2. Choose **Reveal pairing code**.
3. Scan the QR code in the iPhone app.
4. Hide the code when finished.

After the first iPhone is registered, the menu-bar shortcut is hidden to keep
the common menu compact. Pair another phone from **Settings › Pairing › Reveal
pairing code**.

The QR code includes the Mac's stable device UUID, the Mac name supplied by
macOS, Bonjour service name, pairing secret, and current `remote_host`. The UUID
identifies the Mac independently of its display name. Anyone who obtains the
pairing payload can send valid lock commands, so treat it like a password.

If you change `remote_host`, pair again so the iPhone receives the new hostname.

## Manage paired devices

The Mac lists registered iPhones in **Settings › Pairing**, including when each
one last contacted the Mac. The iPhone continues to list its paired Macs. Both
apps show their stable device UUID. The Mac uses the name supplied by macOS.
Each iPhone installation receives a non-editable label such as `iPhone A1B2C3`,
derived from the first six characters of its UUID.

- Removing a Mac in the iPhone app sends an authenticated unpair request. If
  the Mac is offline, the app keeps a local tombstone and retries on a later
  launch.
- Removing an iPhone on the Mac blocks that installation's normal background
  requests. The iPhone removes the Mac from its app, Widget, Control Center,
  and Watch data the next time one of those surfaces contacts the Mac.
- Scanning the QR code again explicitly restores a pairing removed on the Mac.

The Mac has no push connection to an inactive iPhone, so Mac-initiated removal
is reflected on the iPhone at the next status check or lock attempt.

## Replace the pairing secret

**Regenerate pairing secret** immediately invalidates every existing client.
Pair the iPhone again after regeneration. Its Watch, widget, and Control Center
data will then use the new secret.

See [Security](SECURITY.md) for the trust model, command authentication, and
recovery steps for a compromised secret.

## The iPhone cannot find the Mac

- For direct LAN access, confirm both devices are on the same local network.
- Allow Local Network access for Amado in system privacy settings.
- Confirm the Mac menu-bar agent reports **Listening**.
- Guest Wi-Fi and client isolation can block Bonjour and direct device traffic.
- Away from that network, configure an HTTPS tunnel in **Settings › Remote
  access**, test it on the Mac, and pair again so the iPhone receives the
  hostname.
