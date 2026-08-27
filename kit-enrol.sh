#!/usr/bin/env bash
# kit-enrol.sh — the live demo step: enrol a kit VM staged by kit-prep.sh.
#
#   ./kit-enrol.sh demo <TOKEN>
#
# TOKEN comes from the GUI (tenant page -> Mint token, package tunnel-default)
# or from:  RIG_API_BASE=http://app-1.rig.internal:8080 \
#           PKG_API_ENDPOINT=http://app-1.rig.internal:8080 \
#           bash ../scripts/tunnel-mint.sh demo
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG_DIR="$HERE"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
NAME="${1:?usage: $0 <name> <token>}"
TOKEN="${2:?usage: $0 <name> <token>}"
VMLAB="$RIG_DIR/vm/vmlab.sh"

"$VMLAB" exec "$NAME" "
sudo mkdir -p /run/kit-state &&
sudo KIT_TOKEN='$TOKEN' \
     KIT_REPO_DIR=/opt/corewaf-starter-kit \
     CA_BUNDLE=/opt/kit-root.crt \
     sh /opt/kit-shim/install-v2.sh
"
HWID=$(     "$VMLAB" exec "$NAME" 'sudo cat /run/kit-state/hwId            2>/dev/null || true')
CLIENT_IP=$("$VMLAB" exec "$NAME" 'sudo cat /run/kit-state/client.ip       2>/dev/null || true')
SERVER_EP=$("$VMLAB" exec "$NAME" 'sudo cat /run/kit-state/server.endpoint 2>/dev/null || true')
echo
printf '\e[36m==>\e[0m kit enrolled — hwId=%s clientIp=%s serverEndpoint=%s\n' "${HWID:-?}" "${CLIENT_IP:-?}" "${SERVER_EP:-?}"
