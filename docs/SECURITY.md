# Security

Amado is designed around a narrow capability: a paired client may lock a Mac.
It does not expose unlock, login, shell execution, or general remote-control
capabilities.

Amado reaches that capability in two ways: authenticated one-tap commands from
your Apple devices, and local Bluetooth proximity auto-lock when you leave.
Both paths can only lock.

## Trust model

- Pairing creates a random 256-bit secret on the Mac and transfers it through a
  QR code shown only after an explicit reveal action.
- The Mac stores that secret in Keychain. The iPhone stores paired-Mac data in
  its App Group container so the app, widget, Control Center control, and Watch
  relay can use it.
- Every command is authenticated with HMAC-SHA256. The timestamp must be within
  30 seconds, and a nonce may be accepted only once, limiting replay.
- LAN commands use Bonjour discovery and a direct TCP connection.
- Remote commands use HTTPS through a tunnel operated by the user. The local
  HTTP listener binds only to `127.0.0.1:51521`.
- Proximity auto-lock runs on the Mac and observes the selected iPhone's
  Bluetooth signal. It does not expose another network command endpoint.

## Security boundaries

TLS and HMAC solve different problems. The HTTPS tunnel protects traffic in
transit and authenticates the public endpoint. HMAC authenticates the lock
command to Amado even though the tunnel terminates TLS before forwarding it to
the loopback listener.

Anyone with the pairing payload can lock the Mac. They cannot unlock it through
Amado, but unexpected locks can still disrupt work. Do not publish the QR code,
pairing string, Keychain contents, or a configuration backup that contains
client pairing data.

If a pairing secret may have leaked:

1. Open **Settings › Pairing** on the Mac.
2. Choose **Regenerate pairing secret**.
3. Pair the iPhone again.

## Reporting a vulnerability

Please avoid opening a public issue for a vulnerability that could put users at
risk. Use GitHub's private vulnerability reporting for
[PangMo5/Amado](https://github.com/PangMo5/Amado/security/advisories/new) when
available.
