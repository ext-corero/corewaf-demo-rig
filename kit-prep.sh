#!/usr/bin/env bash
# kit-prep.sh — stage a kit VM for a MANUAL demo enrolment (no token, no enrol).
#
# Same VM + staging as kit-up.sh (default NAT, TPM, resolv -> dns VMs, rig root
# CA, starter-kit tree, offline-loaded kit images) but stops short of minting a
# token and running the install shim. The demo step is then a single command
# run inside the VM with a token minted live (GUI: tenant -> Mint token, or
# scripts/tunnel-mint.sh):
#
#   ./kit-prep.sh demo                                  # once, before the demo
#   ./kit-enrol.sh demo <TOKEN>                         # live, during the demo
#
# Re-runnable: an existing VM is left alone and only re-staged.
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

NAME="${1:-demo}"
VMLAB="$RIG_DIR/vm/vmlab.sh"


log() { printf '\e[36m==>\e[0m %s\n' "$*"; }
die() { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 1; }

# ── pre-flight ─────────────────────────────────────────────────────
getent hosts "$RIG_APP_FQDN" >/dev/null 2>&1 \
    || die "$RIG_APP_FQDN doesn't resolve on this host — add it to /etc/hosts ($RIG_APP_IP)"
[[ -z "$KIT_REPO_DIR" || -d "$KIT_REPO_DIR" ]] || die "KIT_REPO_DIR set but not found: $KIT_REPO_DIR"
[[ -f "$RIG_DIR/.v2/ca/root_ca.crt" ]] || die "rig root CA missing at $RIG_DIR/.v2/ca/root_ca.crt"
curl -sf --max-time 5 "http://${RIG_APP_FQDN}:8080/health" >/dev/null || die "rig API not reachable at http://${RIG_APP_FQDN}:8080 — is v2 up?"

# ── stage host artifacts ───────────────────────────────────────────
cp "$RIG_DIR/.v2/ca/root_ca.crt" "$LOG_DIR/root.crt"
# Registry auth for the kit VM's docker (root). Skipped in bundle mode.
DOCKER_AUTH_JSON=""
if [[ "${RIG_BUNDLE:-0}" != 1 ]]; then
    DOCKER_AUTH_JSON="$(reg_docker_config_json)" || exit 1
fi
export DOCKER_AUTH_JSON

# ── boot the kit VM (default NAT) with the v2 install shim mounted ─
if virsh dominfo "rig-$NAME" &>/dev/null; then
    log "VM rig-$NAME already exists — re-staging only"
    virsh domstate "rig-$NAME" | grep -q running || virsh start "rig-$NAME" >/dev/null
else
    log "booting kit VM $NAME (default NAT)"
    KIT_SHIM="$HERE/kit-shim" "$VMLAB" create "$NAME"
fi

log "setting kit resolv.conf -> dns VMs ($RIG_RESOLVERS)"
RESOLV=""
for ns in $RIG_RESOLVERS; do RESOLV="${RESOLV}nameserver ${ns}\n"; done
RESOLV="${RESOLV}nameserver ${RIG_BOOTSTRAP_RESOLVER:-8.8.8.8}\nsearch ${RIG_DOMAIN}\n"
"$VMLAB" exec "$NAME" "printf '%b' '${RESOLV}' | sudo tee /etc/resolv.conf >/dev/null"

log "staging root CA + kit + images onto VM"
"$VMLAB" scp "$NAME" "$LOG_DIR/root.crt" /tmp/root.crt
"$VMLAB" exec "$NAME" 'sudo cp /tmp/root.crt /opt/kit-root.crt'
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

# ── in-VM customer path (bootstrap.sh) prerequisites ────────────────
# The demo can also be run from INSIDE the VM with the public curl-pipe
# bootstrap. That needs git (clone), a console password, and two rig-specific
# bits the public kit doesn't carry: the rig root CA (runtime/operator-ca.crt)
# and the TPM PKCS#11 env (NL_PKCS11_PIN / TPM2_PKCS11_STORE — without it
# network-loader fails "PIN required for GenerateKeypair"). Both are staged in
# /opt/kit-demo and applied by the `corewaf-demo-up` helper.
log "staging in-VM demo helper (git, console login alpine/alpine, /opt/kit-demo, corewaf-demo-up)"
"$VMLAB" exec "$NAME" 'command -v git >/dev/null || sudo apk add --no-cache git >/dev/null 2>&1; echo alpine:alpine | sudo chpasswd'
"$VMLAB" exec "$NAME" 'sudo mkdir -p /opt/kit-demo && sudo cp /opt/kit-root.crt /opt/kit-demo/operator-ca.crt && sudo tee /opt/kit-demo/docker-compose.override.yml >/dev/null <<EOF2
# rig demo override — TPM PKCS#11 wiring for the swtpm-backed kit VM.
services:
  tunnel:
    environment:
      NL_PKCS11_PIN: "0000"
      TPM2_PKCS11_STORE: "/var/lib/tunnel/pkcs11-store"
EOF2
sudo tee /usr/local/bin/corewaf-demo-up >/dev/null <<EOF2
#!/bin/sh
# corewaf-demo-up — finish a NO_UP=1 bootstrap: drop in the rig CA + TPM
# override, bring the kit up, wait for the tunnel to go healthy.
set -eu
KIT="\${1:-\$HOME/corewaf-starter-kit}"
cd "\$KIT"
cp /opt/kit-demo/operator-ca.crt runtime/operator-ca.crt
cp /opt/kit-demo/docker-compose.override.yml docker-compose.override.yml
sudo docker compose up -d
printf "waiting for tunnel"
for i in \$(seq 1 60); do
  [ "\$(sudo docker compose ps --format "{{.Health}}" tunnel 2>/dev/null | head -1)" = healthy ] && { echo " healthy"; break; }
  printf .; sleep 3
done
sudo docker logs corewaf-tunnel 2>&1 | grep -E "redeem|foundation tier ready" | tail -2
EOF2
sudo chmod +x /usr/local/bin/corewaf-demo-up'

# ── readiness check (what the demo relies on) ──────────────────────
log "readiness: rig reachability from the VM"
"$VMLAB" exec "$NAME" "
set -e
getent hosts ${RIG_GW_1_FQDN} >/dev/null && echo '  dns  : ${RIG_GW_1_FQDN} resolves'
curl -sf --cacert /opt/kit-root.crt https://${RIG_GW_1_FQDN}/health >/dev/null && echo '  edge : https://${RIG_GW_1_FQDN}/health ok (rig CA trusted)'
ls /dev/tpm0 >/dev/null && echo '  tpm  : /dev/tpm0 present'
sudo docker image ls --format '  img  : {{.Repository}}:{{.Tag}}' | grep -E 'network-loader|caddy-waf'
"
echo
log "kit VM rig-$NAME staged and NOT enrolled."
echo "  enrol (host):  $HERE/kit-enrol.sh $NAME <TOKEN>"
echo "  enrol (in VM): NO_UP=1 TOKEN=<TOKEN> bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-starter-kit/main/bootstrap.sh) && corewaf-demo-up"
echo "  login       :  alpine / alpine on the console, or: $VMLAB exec $NAME"
echo "  console     :  $VMLAB console $NAME     (Ctrl-] to detach)"
echo "  destroy     :  $VMLAB destroy $NAME"
