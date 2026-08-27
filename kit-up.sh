#!/usr/bin/env bash
# kit-up.sh — boot one external kit VM and enroll it against the v2 rig.
#
# v2 adaptation of vm/runner.sh: the kit VM sits on libvirt's default NAT
# (external), routes to the routed rig subnet through this host, resolves
# rig.internal via the dns VMs, redeems at gw-1.rig.internal:443 and WGs to
# gw-1.rig.internal:51820. Uses the v2 rig root CA + the v2 install shim.
#
# Usage: ./kit-up.sh [name]    (default: kit-v2)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # repo root
RIG_DIR="$HERE"                              # repo root
WORKSPACE="$(cd "$RIG_DIR/.." && pwd)"
KIT_REPO_DIR="${KIT_REPO_DIR:-$WORKSPACE/waf/corewaf-starter-kit}"
LOG_DIR="${LOG_DIR:-$RIG_DIR/.cache/vm-runner-v2}"
mkdir -p "$LOG_DIR"
# shellcheck disable=SC1091
source "$HERE/inventory.env"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

NAME="${1:-kit-v2}"
VMLAB="$RIG_DIR/vm/vmlab.sh"   # single-host driver: default NAT + alpine-prepared (TPM/WG/docker)

# Kit images (private GHCR) — saved from the host docker, loaded offline in
# the VM. Same set vm/runner.sh ships.
IMAGES_DEFAULT=(
    "ghcr.io/ext-corero/waf/network-loader:0.1.0"
    "ghcr.io/ext-corero/waf/caddy-bridge:tunnel-v0"
    "ghcr.io/ext-corero/waf/caddy-waf:latest"
    "ghcr.io/ext-corero/services/core/caddy-docker-proxy:1.0.0"
    "grafana/alloy:v1.7.5"
    "valkey/valkey:8"
)
read -r -a IMAGES <<<"${RIG_KIT_IMAGES:-${IMAGES_DEFAULT[*]}}"

log() { printf '\e[36m==>\e[0m %s\n' "$*"; }
die() { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 1; }

# ── pre-flight ─────────────────────────────────────────────────────
getent hosts "$RIG_APP_FQDN" >/dev/null 2>&1 \
    || die "$RIG_APP_FQDN doesn't resolve on this host — add it to /etc/hosts ($RIG_APP_IP) or point your resolver at $RIG_DNS_1_IP"
[[ -d "$KIT_REPO_DIR" ]] || die "starter-kit not found at $KIT_REPO_DIR"
[[ -f "$RIG_DIR/.v2/ca/root_ca.crt" ]] || die "rig root CA missing at $RIG_DIR/.v2/ca/root_ca.crt"

# ── mint a tunnel token against the app VM ─────────────────────────
log "minting provisioning token via $RIG_APP_FQDN"
MINT_OUT="$(RIG_API_BASE="http://${RIG_APP_FQDN}:8080" \
            PKG_API_ENDPOINT="http://${RIG_APP_FQDN}:8080" \
            bash "$RIG_DIR/scripts/tunnel-mint.sh" "rig2-$NAME" 2>&1)"
TOKEN="$(echo "$MINT_OUT" | awk -F= '/^provisioning_token=/{print $2; exit}')"
[[ -n "$TOKEN" ]] || { echo "$MINT_OUT" >&2; die "token mint failed"; }
log "  → token ${TOKEN:0:32}... (len ${#TOKEN})"

# ── stage host artifacts ───────────────────────────────────────────
cp "$RIG_DIR/.v2/ca/root_ca.crt" "$LOG_DIR/root.crt"
IMAGES_TAR="$LOG_DIR/kit-images.tar"
if [[ ! -s "$IMAGES_TAR" || "${REBUILD_IMAGES:-0}" == "1" ]]; then
    log "saving ${#IMAGES[@]} kit images for offline load"
    docker save -o "$IMAGES_TAR" "${IMAGES[@]}"
fi
KIT_TAR="$LOG_DIR/kit.tgz"
( cd "$KIT_REPO_DIR" && tar --exclude='./.git' --exclude='./.claude' --exclude='./runtime' -czf "$KIT_TAR" . )

# ── boot the kit VM (default NAT) with the v2 install shim mounted ─
log "booting kit VM $NAME (default NAT)"
KIT_SHIM="$HERE/kit-shim" "$VMLAB" create "$NAME"

# ── point the kit's resolver at the dns VMs (resolves rig.internal) ─
log "setting kit resolv.conf -> dns VMs ($RIG_RESOLVERS)"
RESOLV=""
for ns in $RIG_RESOLVERS; do RESOLV="${RESOLV}nameserver ${ns}\n"; done
RESOLV="${RESOLV}nameserver ${RIG_BOOTSTRAP_RESOLVER:-8.8.8.8}\nsearch ${RIG_DOMAIN}\n"
# busybox sh has no here-strings; printf '%b' the content into resolv.conf.
"$VMLAB" exec "$NAME" "printf '%b' '${RESOLV}' | sudo tee /etc/resolv.conf >/dev/null && cat /etc/resolv.conf"

# ── stage onto the VM + load images ────────────────────────────────
log "staging root CA + kit + images onto VM"
"$VMLAB" scp "$NAME" "$LOG_DIR/root.crt" /tmp/root.crt
"$VMLAB" scp "$NAME" "$KIT_TAR"          /tmp/kit.tgz
"$VMLAB" scp "$NAME" "$IMAGES_TAR"       /tmp/images.tar
"$VMLAB" exec "$NAME" 'set -e; sudo rm -rf /opt/corewaf-starter-kit; sudo mkdir -p /opt/corewaf-starter-kit; sudo tar -xzf /tmp/kit.tgz -C /opt/corewaf-starter-kit'
"$VMLAB" exec "$NAME" 'command -v docker >/dev/null || { sudo apk add --no-cache docker docker-cli-compose >/dev/null; sudo rc-update add docker default >/dev/null; sudo rc-service docker start >/dev/null; }'
log "loading kit images into VM docker"
"$VMLAB" exec "$NAME" 'sudo docker load -i /tmp/images.tar | tail -3'

# ── run the v2 install shim ────────────────────────────────────────
log "enrolling kit (install-v2.sh)"
"$VMLAB" exec "$NAME" "
sudo mkdir -p /run/kit-state &&
sudo KIT_TOKEN='$TOKEN' \
     KIT_REPO_DIR=/opt/corewaf-starter-kit \
     CA_BUNDLE=/tmp/root.crt \
     sh /opt/kit-shim/install-v2.sh
"

# ── read back state ────────────────────────────────────────────────
HWID=$(     "$VMLAB" exec "$NAME" 'sudo cat /run/kit-state/hwId            2>/dev/null || true')
CLIENT_IP=$("$VMLAB" exec "$NAME" 'sudo cat /run/kit-state/client.ip       2>/dev/null || true')
SERVER_EP=$("$VMLAB" exec "$NAME" 'sudo cat /run/kit-state/server.endpoint 2>/dev/null || true')
echo
log "kit enrolled — hwId=${HWID:-?} clientIp=${CLIENT_IP:-?} serverEndpoint=${SERVER_EP:-?}"
echo "(vm: rig-$NAME — vmlab.sh console $NAME / destroy $NAME)"
