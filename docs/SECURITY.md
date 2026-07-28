# Security

Amado is designed around a narrow capability: a paired client may lock a Mac
and read whether its current login session is locked. It does not expose
unlock, login, shell execution, or general remote-control capabilities.

Amado reaches that capability in two ways: authenticated one-tap commands from
your Apple devices, and local Bluetooth proximity auto-lock when you leave.
Both paths can only lock.

## Trust model

- Pairing creates a random 256-bit secret on the Mac and transfers it through a
  QR code shown only after an explicit reveal action.
- The Mac stores that secret in Keychain. The iPhone stores paired-Mac data in
  its App Group container so the app, widget, Control Center control, and Watch
  relay can use it.
- Each Mac and iPhone installation has a stable UUID. Display names are never
  used as authentication or revocation identifiers. The Mac uses the iPhone
  UUID to show paired phones and reject normal requests from an installation
  removed in Settings. Scanning the QR code is the explicit path that restores
  a removed installation.
- Every command and response is authenticated with HMAC-SHA256. Command
  timestamps must be within 30 seconds, and a nonce may be accepted only once,
  limiting replay. A response carries the matching command nonce and its own
  freshness timestamp.
- Status responses contain the Mac's current locked or unlocked state plus its
  stable UUID, macOS-supplied name, and Bonjour service name so companion
  surfaces can keep their paired record current. Amado does not expose a
  session history or retain a remote activity log.
- LAN commands use Bonjour discovery and a direct TCP connection.
- Remote commands use HTTPS through a tunnel operated by the user. The local
  HTTP listener binds only to `127.0.0.1:51521`.
- Proximity auto-lock runs on the Mac and observes the selected iPhone's
  Bluetooth signal. It does not expose another network command endpoint.

## Security boundaries

TLS and HMAC solve different problems. The HTTPS tunnel protects traffic in
transit and authenticates the public endpoint. HMAC authenticates commands and
their matching responses even though the tunnel terminates TLS before
forwarding them to the loopback listener.

Anyone with the pairing payload can lock the Mac. They cannot unlock it through
Amado, but unexpected locks can still disrupt work. Do not publish the QR code,
pairing string, Keychain contents, or a configuration backup that contains
client pairing data.

Per-device removal is an application-level control around the stable client
identifier. Because all phones paired from the same QR payload hold the same
lock-only secret, regenerate the pairing secret if a device or pairing payload
may be compromised. Regeneration is the cryptographic way to invalidate every
copy of that credential.

Device UUIDs are identifiers, not secrets. Possessing a UUID does not authorize
a command; the pairing secret and valid HMAC are still required.

If a pairing secret may have leaked:

1. Open **Settings › Pairing** on the Mac.
2. Choose **Regenerate pairing secret**.
3. Pair the iPhone again.

## Reporting a vulnerability

Please avoid opening a public issue for a vulnerability that could put users at
risk. Use GitHub's private vulnerability reporting for
[PangMo5/Amado](https://github.com/PangMo5/Amado/security/advisories/new) when
available.
