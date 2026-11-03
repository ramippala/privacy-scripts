# cf-warp

Minimal Cloudflare WARP client image: official `warp-svc` in TUN mode plus a
SOCKS5 listener, meant to sit in front of the `wirehole` WireGuard stack so
selected egress leaves through Cloudflare instead of the VPS IP.

## Why it is small

| Piece | Choice |
| --- | --- |
| Base | `debian:bookworm-slim`, docs/locales excluded |
| Binaries | only `warp-svc` + `warp-cli`, stripped (`warp-dex`, `warp-diag`, Flutter GUI dropped) |
| Proxy | `microsocks` (~40 KB) instead of gost |
| Runtime deps | just the shared libs the daemon links + `iproute2`/`nftables` |

Result: **~72 MB compressed / ~297 MB on disk**, versus the Ubuntu-based
`caomingjun/warp` image. No dbus daemon, no sudo, no systemd, no build tools in
the final layer.

## Build

```bash
docker build -t cf-warp:local cf-warp/
```

Multi-arch (`linux/amd64`, `linux/arm64`) builds run in GitHub Actions
(`.github/workflows/cf-warp.yml`) and publish to
`ghcr.io/ramippala/cf-warp` on pushes to `cf-warp`.

Pin a WARP client version with `--build-arg WARP_VERSION=2026.8.2115.0`
(default `latest` = whatever the Cloudflare repo currently serves).

## Run

Standalone (attaches to the existing `wirehole` network):

```bash
cd cf-warp && docker compose up -d
```

Required runtime knobs:

- `--cap-add NET_ADMIN` (TUN + nftables rules)
- `/dev/net/tun` device (plus `MKNOD` if the node must be created)
- `net.ipv4.conf.all.src_valid_mark=1`
- persistent volume on `/var/lib/cloudflare-warp` (keeps the registration)

## Verify

```bash
# through the proxy: must show warp=on and a 2a09:bac* (WARP) exit IP
curl -s --socks5-hostname 172.31.255.5:1080 https://www.cloudflare.com/cdn-cgi/trace

# direct: still the VPS IP (selective masking is the point)
curl -s https://www.cloudflare.com/cdn-cgi/trace
```

`docker exec warp warp-cli --accept-tos status` → `Connected`.

## Use from other containers

SOCKS5 only inside the `wirehole` network:

```yaml
environment:
  ALL_PROXY: socks5://172.31.255.5:1080
```

or per command: `curl --socks5-hostname 172.31.255.5:1080 ...`.

Optional auth: set `SOCKS_USER` + `SOCKS_PASS` (both required).

The listener is TCP-only (microsocks). For UDP/ICMP or to make a whole container
egress through WARP, give that container `network_mode: "service:warp"` and
publish its ports on the `warp` service instead.

## Registration behaviour

- First start with an empty volume: `registration new` → `connect` → state saved.
- Later starts reuse `reg.json` (no re-registration, no new device each boot).
- Stale/broken registration is retried once after `registration delete`.
- `WARP_LICENSE_KEY` is applied when set (WARP+); leave empty for free tier.
- qlog is disabled to keep the state volume from filling up.
