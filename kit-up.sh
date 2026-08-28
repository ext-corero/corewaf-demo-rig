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
KIT_REPO_DIR="${KIT_REPO_DIR:-}"          # opt-in: stage a LOCAL starter-kit checkout instead of cloning
KIT_REPO_URL="${KIT_REPO_URL:-https://github.com/ext-corero/corewaf-starter-kit.git}"
KIT_REF="${KIT_REF:-main}"
LOG_DIR="${LOG_DIR:-$RIG_DIR/.cache/vm-runner-v2}"
mkdir -p "$LOG_DIR"
# shellcheck disable=SC1091
source "$HERE/inventory.env"
# shellcheck disable=SC1091
source "$HERE/lib/registry.sh"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

NAME="${1:-kit-v2}"
VMLAB="$RIG_DIR/vm/vmlab.sh"   # single-host driver: default NAT + alpine-prepared (TPM/WG/docker)


log() { printf '\e[36m==>\e[0m %s\n' "$*"; }
die() { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 1; }

# ── pre-flight ─────────────────────────────────────────────────────
getent hosts "$RIG_APP_FQDN" >/dev/null 2>&1 \
    || die "$RIG_APP_FQDN doesn't resolve on this host — add it to /etc/hosts ($RIG_APP_IP) or point your resolver at $RIG_DNS_1_IP"
[[ -z "$KIT_REPO_DIR" || -d "$KIT_REPO_DIR" ]] || die "KIT_REPO_DIR set but not found: $KIT_REPO_DIR"
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
# Registry auth for the kit VM's docker (root). Skipped in bundle mode.
DOCKER_AUTH_JSON=""
if [[ "${RIG_BUNDLE:-0}" != 1 ]]; then
    DOCKER_AUTH_JSON="$(reg_docker_config_json)" || exit 1
fi
export DOCKER_AUTH_JSON

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
# starter-kit: from its public repo (KIT_REF), or a local checkout when KIT_REPO_DIR is set
"$VMLAB" exec "$NAME" 'command -v docker >/dev/null || { sudo apk add --no-cache docker docker-cli-compose git >/dev/null; sudo rc-update add docker default >/dev/null; sudo rc-service docker start >/dev/null; }; command -v git >/dev/null || sudo apk add --no-cache git >/dev/null'
if [[ -n "$KIT_REPO_DIR" ]]; then
    log "staging LOCAL starter-kit from $KIT_REPO_DIR"
    ( cd "$KIT_REPO_DIR" && tar --exclude='./.git' --exclude='./.claude' --exclude='./runtime' -czf "$LOG_DIR/kit.tgz" . )
    "$VMLAB" scp "$NAME" "$LOG_DIR/kit.tgz" /tmp/kit.tgz
    "$VMLAB" exec "$NAME" 'set -e; sudo rm -rf /opt/corewaf-starter-kit; sudo mkdir -p /opt/corewaf-starter-kit; sudo tar -xzf /tmp/kit.tgz -C /opt/corewaf-starter-kit'
else
    log "cloning starter-kit $KIT_REPO_URL@$KIT_REF into the VM"
    "$VMLAB" exec "$NAME" "set -e; sudo rm -rf /opt/corewaf-starter-kit; sudo git clone -q --depth 1 --branch '$KIT_REF' '$KIT_REPO_URL' /opt/corewaf-starter-kit"
fi
# registry auth (re)written on every staging so a re-used VM gets a fresh 12h token
if [[ -n "$DOCKER_AUTH_JSON" ]]; then
    printf '%s' "$DOCKER_AUTH_JSON" > "$LOG_DIR/docker-config.json"; chmod 600 "$LOG_DIR/docker-config.json"
    "$VMLAB" scp "$NAME" "$LOG_DIR/docker-config.json" /tmp/docker-config.json
    "$VMLAB" exec "$NAME" 'sudo mkdir -p /root/.docker && sudo mv /tmp/docker-config.json /root/.docker/config.json && sudo chmod 600 /root/.docker/config.json'
fi
if [[ "${RIG_BUNDLE:-0}" == 1 ]]; then
    log "loading kit images from bundle"
    "$VMLAB" scp "$NAME" "$RIG_DIR/.v2/bundle/kit-images.tar" /tmp/images.tar
    "$VMLAB" exec "$NAME" 'sudo docker load -i /tmp/images.tar | tail -3'
else
    log "pulling kit images from the CoreWAF registry inside the VM (re-tagged to the names the starter-kit compose expects)"
    reg_kit_pull_script > "$LOG_DIR/kit-pull.sh"
    "$VMLAB" scp "$NAME" "$LOG_DIR/kit-pull.sh" /tmp/kit-pull.sh
    "$VMLAB" exec "$NAME" 'sudo sh /tmp/kit-pull.sh'
fi

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
