# Remote Access

Remote access is optional. Amado listens on `127.0.0.1:51521`; you operate an
HTTPS tunnel that maps a public hostname to that loopback port. Amado always
tries direct LAN delivery first and falls back to the tunnel only when the Mac
cannot be reached locally.

This extends Amado's one-tap controls beyond the LAN. Walk-away auto-lock is a
separate, equally central path that runs locally on the Mac.

Enter only the hostname in **Amado › Settings › Remote access**, then choose
**Test connection**. The matching `config.toml` key is documented in the
[configuration reference](CONFIGURATION.md).

## Cloudflare Tunnel

Use this when you own a domain managed by Cloudflare and want a stable host.

```sh
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create amado
cloudflared tunnel route dns amado amado.example.com
```

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: amado
credentials-file: /Users/you/.cloudflared/TUNNEL-UUID.json
ingress:
  - hostname: amado.example.com
    service: http://127.0.0.1:51521
  - service: http_status:404
```

Run the tunnel:

```sh
cloudflared tunnel run amado
```

Set `remote_host = "amado.example.com"`.

## Tailscale Funnel

Use this when you prefer a `ts.net` hostname and do not need your own domain.
Funnel must be enabled for the tailnet.

```sh
brew install tailscale
tailscale up
tailscale funnel --bg 51521
tailscale funnel status
```

Set `remote_host` to the reported hostname, for example
`"my-mac.example-tailnet.ts.net"`.

## ngrok

Use a static ngrok domain so the paired hostname does not change between runs.

```sh
brew install ngrok
ngrok config add-authtoken YOUR_TOKEN
ngrok http --domain=your-static.ngrok-free.app 51521
```

Set `remote_host = "your-static.ngrok-free.app"`.

> The tunnel publishes a lock endpoint to the internet. HTTPS protects the
> connection, while Amado's HMAC authentication protects the command. Keep the
> pairing secret private and use a tunnel provider you trust.

## Troubleshooting

- Confirm the tunnel forwards to `http://127.0.0.1:51521` on the Mac.
- Enter only a hostname, without `https://`, a port, or a path.
- Verify the tunnel process is running before using **Test connection**.
- Pair again after changing the hostname.
