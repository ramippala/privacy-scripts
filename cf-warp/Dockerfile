# syntax=docker/dockerfile:1.7
# Minimal Cloudflare WARP client image: TUN-mode daemon + SOCKS5 listener.
# Only the official warp-svc/warp-cli binaries are kept; GUI payloads are dropped.

ARG DEBIAN_VERSION=bookworm

# ---------- fetch: pull the official .deb and keep just the two binaries ----------
FROM debian:${DEBIAN_VERSION}-slim AS fetch

ARG DEBIAN_VERSION
ARG TARGETARCH
ARG WARP_VERSION=latest

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl binutils xz-utils; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/warp

RUN set -eux; \
    arch="${TARGETARCH:-amd64}"; \
    base="https://pkg.cloudflareclient.com"; \
    curl -fsSL "$base/dists/${DEBIAN_VERSION}/main/binary-${arch}/Packages" -o Packages; \
    if [ "$WARP_VERSION" = "latest" ]; then \
        debfile="$(awk '/^Package: cloudflare-warp$/{p=1} p&&/^Filename:/{print $2; exit}' Packages)"; \
    else \
        debfile="$(awk -v ver="$WARP_VERSION" '/^Package: cloudflare-warp$/{p=1} p&&/^Version:/{v=$2} p&&/^Filename:/{f=$2} p&&/^$/{if(v==ver){print f; exit} p=0}' Packages)"; \
    fi; \
    [ -n "$debfile" ] || { echo "WARP_VERSION $WARP_VERSION not found in repo" >&2; exit 1; }; \
    echo "Fetching $debfile"; \
    curl -fsSL "$base/$debfile" -o warp.deb; \
    dpkg-deb -x warp.deb root; \
    mkdir -p /out; \
    cp root/bin/warp-svc root/bin/warp-cli /out/; \
    strip --strip-all /out/warp-svc /out/warp-cli; \
    chmod 0755 /out/warp-svc /out/warp-cli; \
    /out/warp-cli --version || true

# ---------- runtime ----------
FROM debian:${DEBIAN_VERSION}-slim

# Drop docs/locales from every package to keep the layer small.
RUN set -eux; \
    printf 'path-exclude=/usr/share/doc/*\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/locale/*\n' \
      > /etc/dpkg/dpkg.cfg.d/01-nodoc; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libdbus-1-3 \
      libnss3 \
      libtss2-esys-3.0.2-0 \
      libtss2-tctildr0 \
      iproute2 \
      nftables \
      microsocks \
      procps; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

COPY --from=fetch /out/warp-svc /usr/local/bin/warp-svc
COPY --from=fetch /out/warp-cli /usr/local/bin/warp-cli
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
 && mkdir -p /var/lib/cloudflare-warp

ENV WARP_SLEEP=2 \
    SOCKS_PORT=1080 \
    WARP_LICENSE_KEY=

VOLUME ["/var/lib/cloudflare-warp"]
EXPOSE 1080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
