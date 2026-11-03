#!/bin/sh
set -eu

STATE_DIR=/var/lib/cloudflare-warp
mkdir -p "$STATE_DIR"

# Podman / older runtimes may not create the tun node; NET_ADMIN + MKNOD allow it.
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# warp-svc is the long-lived daemon; keep its PID so signals shut it down cleanly.
warp-svc &
WARP_PID=$!

shutdown() {
    kill "$WARP_PID" 2>/dev/null || true
    wait "$WARP_PID" 2>/dev/null || true
    exit 0
}
trap shutdown INT TERM

# Wait until the daemon answers on its local socket.
i=0
while ! warp-cli --accept-tos status >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "warp-svc did not become ready in 60s" >&2
        exit 1
    fi
    sleep 1
done

if [ ! -f "$STATE_DIR/reg.json" ]; then
    echo "Registering WARP client..."
    if ! warp-cli --accept-tos registration new; then
        echo "Registration failed; clearing stale state and retrying..." >&2
        warp-cli --accept-tos registration delete || true
        warp-cli --accept-tos registration new
    fi
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        warp-cli --accept-tos registration license "$WARP_LICENSE_KEY"
    fi
else
    echo "Existing WARP registration found; reusing it."
fi

warp-cli --accept-tos connect

# Keep the state volume small: WARP writes verbose qlog files by default.
warp-cli --accept-tos debug qlog disable >/dev/null 2>&1 || true

# Optional: act as an L3 NAT gateway for traffic forwarded here by other
# containers (e.g. a WireGuard server routing client egress via this address).
# Without the masquerade WARP sees private source addresses on its TUN device
# and drops the packets as martians.
if [ -n "${WARP_ENABLE_NAT:-}" ]; then
    echo "Enabling NAT gateway mode..."
    warp-cli --accept-tos mode warp
    warp-cli --accept-tos connect
    sleep "${WARP_SLEEP:-2}"

    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true

    nft add table ip nat 2>/dev/null || true
    nft add chain ip nat WARP_NAT '{ type nat hook postrouting priority 100 ; }' 2>/dev/null \
        || nft flush chain ip nat WARP_NAT
    nft add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade

    nft add table ip mangle 2>/dev/null || true
    nft add chain ip mangle forward '{ type filter hook forward priority mangle ; }' 2>/dev/null \
        || nft flush chain ip mangle forward
    nft add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu

    nft add table ip6 nat 2>/dev/null || true
    nft add chain ip6 nat WARP_NAT '{ type nat hook postrouting priority 100 ; }' 2>/dev/null \
        || nft flush chain ip6 nat WARP_NAT
    nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade

    nft add table ip6 mangle 2>/dev/null || true
    nft add chain ip6 mangle forward '{ type filter hook forward priority mangle ; }' 2>/dev/null \
        || nft flush chain ip6 mangle forward
    nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
fi

# Give the tunnel time to come up before the proxy starts accepting clients.
sleep "${WARP_SLEEP:-2}"

set -- -i 0.0.0.0 -p "${SOCKS_PORT:-1080}"
if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
    set -- "$@" -u "$SOCKS_USER" -P "$SOCKS_PASS"
fi

echo "Starting SOCKS5 listener on 0.0.0.0:${SOCKS_PORT:-1080}"
exec microsocks "$@"
