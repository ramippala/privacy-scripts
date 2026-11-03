#!/bin/sh
set -eu

status="$(warp-cli --accept-tos status 2>&1 || true)"
echo "$status"

case "$status" in
    *Connected*|*connected*) exit 0 ;;
    *) exit 1 ;;
esac
