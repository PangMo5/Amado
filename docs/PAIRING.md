# Pairing

Pairing transfers an authenticated lock capability from the Mac to the iPhone.
The Apple Watch, widget, and Control Center use the iPhone's paired-Mac data.
This powers Amado's one-tap path; walk-away auto-lock is configured separately
on the Mac, and both paths trigger the same lock-only action.

## Pair an iPhone

1. Open **Amado › Settings › Pairing** on the Mac.
2. Choose **Reveal pairing code**.
3. Scan the QR code in the iPhone app.
4. Hide the code when finished.

The QR code includes the Mac name, pairing secret, and current `remote_host`.
Anyone who obtains the pairing payload can send valid lock commands, so treat
it like a password.

If you change `remote_host`, pair again so the iPhone receives the new hostname.

## Replace the pairing secret

**Regenerate pairing secret** immediately invalidates every existing client.
Pair the iPhone again after regeneration; its Watch, widget, and Control Center
data will then use the new secret.

See [Security](SECURITY.md) for the trust model, command authentication, and
recovery steps for a compromised secret.

## The iPhone cannot find the Mac

- Confirm both devices are on the same local network.
- Allow Local Network access for Amado in system privacy settings.
- Confirm the Mac menu-bar agent reports **Listening**.
- Guest Wi-Fi and client isolation can block Bonjour and direct device traffic.
