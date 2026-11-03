# cf-warp

Minimal Cloudflare WARP client image: official `warp-svc` in TUN mode plus a
SOCKS5 listener, for sending selected egress through Cloudflare instead of the
host's own IP.

## Why it is small

| Piece | Choice |
| --- | --- |
| Base | `debian:bookworm-slim`, docs/locales excluded |
| Binaries | only `warp-svc` + `warp-cli`, stripped (GUI, `warp-dex`, `warp-diag` dropped) |
| Proxy | `microsocks` (~40 KB) instead of gost |
| Runtime deps | just the shared libs the daemon links + `iproute2`/`nftables` |

Result: **~72 MB compressed / ~207 MB pulled**. No dbus daemon, no sudo, no
systemd, no build tools in the final layer.

## Build

```bash
docker build -t cf-warp:local cf-warp/
```

Multi-arch (`linux/amd64`, `linux/arm64`) builds run in GitHub Actions
(`.github/workflows/cf-warp.yml`) and publish to
`ghcr.io/ramippala/cf-warp` on pushes to `cf-warp`. Images are tagged
`latest`, `cf-warp` (branch), `sha-<short-commit>`, and
`warp-<warp-version>`, the version resolved from the Cloudflare package repo
at build time.

Pin a WARP client version with `--build-arg WARP_VERSION=2026.8.2115.0`
(default `latest` = whatever the Cloudflare repo currently serves).

## Run

```bash
cd cf-warp && docker compose up -d
```

The example compose file creates its own bridge network and publishes the
listener on `127.0.0.1:1080`, so it does not depend on any existing subnet or
container IP. To place it beside another stack, drop the `ports:` block, attach
that stack's (external) network, and address it as `warp:1080`.

Required runtime knobs:

- `--cap-add NET_ADMIN` (TUN + nftables rules)
- `/dev/net/tun` device (plus `MKNOD` if the node must be created)
- `net.ipv4.conf.all.src_valid_mark=1`
- persistent volume on `/var/lib/cloudflare-warp` (keeps the registration)
- `net.ipv4.ip_forward=1` — only for [NAT gateway mode](#route-other-containers-through-warp-l3-gateway).
  Set it through compose/`--sysctl`; Docker mounts `/proc/sys` read-only, so
  the entrypoint cannot enable it itself.

## Verify

```bash
# through the proxy: must show warp=on and a 2a09:bac* (WARP) exit IP
curl -s --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace

# from a container routed through the gateway: must also show warp=on
curl -s https://www.cloudflare.com/cdn-cgi/trace

# direct: still the host's own IP (selective masking is the point)
curl -s https://www.cloudflare.com/cdn-cgi/trace
```

`docker exec warp warp-cli --accept-tos status` → `Connected`.

## Use from other containers

Put the consumer on the same Docker network and use the service name — no fixed
IP needed:

```yaml
environment:
  ALL_PROXY: socks5://warp:1080
```

or per command: `curl --socks5-hostname warp:1080 ...`.

Optional auth: set `SOCKS_USER` + `SOCKS_PASS` (both required).

The listener is TCP-only (microsocks). For UDP/ICMP or to make a whole container
egress through WARP, give that container `network_mode: "service:warp"` and
publish its ports on the `warp` service instead.

## Route other containers through WARP (L3 gateway)

Set `WARP_ENABLE_NAT=1` to use the container as a router: traffic forwarded to
it is masqueraded into the tunnel, so WARP sees the tunnel address instead of
the original private source. This is how the WireGuard stack sends client
egress out through WARP while the host's own traffic keeps the VPS IP.

```yaml
services:
  warp:
    environment:
      WARP_ENABLE_NAT: "1"
    sysctls:
      net.ipv4.ip_forward: "1"            # required
      net.ipv4.conf.all.src_valid_mark: "1"
```

With it enabled the entrypoint:

- switches to `warp` mode and reconnects,
- adds `nftables` masquerade on `oifname "CloudflareWARP"` for IPv4 and IPv6,
- clamps TCP MSS in the forward hook so PMTU works through the tunnel,
- best-effort enables the forwarding sysctls (only effective on runtimes that
  allow writable `/proc/sys`; Docker needs the `sysctls:` entry above).

Point the consumer's routing at the container (its address on your Docker
network):

```bash
WARP_IP=<warp-container-ip>
ip route add default via "$WARP_IP"          # whole namespace/container
ip route add 1.1.1.1/32 via "$WARP_IP"       # or selected destinations
```

IPv6 needs its own sysctl (`net.ipv6.conf.all.forwarding=1`); it is not enabled
by default. The SOCKS listener is unaffected and remains TCP-only.

## Registration behaviour

- First start with an empty volume: `registration new` → `connect` → state saved.
- Later starts reuse `reg.json` (no re-registration, no new device each boot).
- Stale/broken registration is retried once after `registration delete`.
- `WARP_LICENSE_KEY` is applied when set (WARP+); leave empty for free tier.
- qlog is disabled to keep the state volume from filling up.
