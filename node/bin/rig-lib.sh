#!/usr/bin/env bash
# rig-lib.sh — shared by the node image scripts. Expects the rig env
# (inventory.env + images.env, loaded by compose env_file) in the environment.
# Paths are overridable so the SAME scripts drive both hypervisor flavours:
# container mode (defaults below = the node-image volumes) and pure-QEMU host
# mode (qemu/rig-qemu exports its own tree under the checkout's .qemu/).
: "${RIG_ROOT:=/rig}"                       # parent of the repo checkout
: "${V2_DIR:=$RIG_ROOT/v2}"                 # the repo checkout (exported to guests as /opt/v2)
: "${BASE_DIR:=$RIG_ROOT/base}"             # pulled VM base image (generations)
: "${CA_DIR:=$RIG_ROOT/ca}"                 # rig root CA
: "${SECRETS_DIR:=$RIG_ROOT/shared-secrets}" # rw; app writes, gw/obs read
: "${AUTH_DIR:=$RIG_ROOT/auth}"             # docker-config.json (+aws-credentials)
: "${SSH_DIR:=$RIG_ROOT/ssh}"               # id_lab keypair
: "${STATE_DIR:=/state}"                    # per-node state (disk.qcow2, tpm/, share/)
: "${RUN_DIR:=/run}"                        # per-node sockets + rendered seed
: "${RIG_OS:=flatcar}"                      # infra guest OS: flatcar (default) | alpine (legacy); kits always alpine
# Guest login/privilege words. Flatcar infra guests: core/sudo; Alpine: alpine/doas.
if [[ "$RIG_OS" == flatcar && "${ROLE:-}" != kit ]]; then GUEST_USER=core; GUEST_SUDO=sudo; else GUEST_USER=alpine; GUEST_SUDO=doas; fi
guest_user_for() { case "$1" in kit*) echo alpine ;; *) if [[ "$RIG_OS" == flatcar ]]; then echo core; else echo alpine; fi ;; esac; }
guest_sudo_for() { if [[ "$(guest_user_for "$1")" == core ]]; then echo sudo; else echo doas; fi; }
docker_start_cmd() { if [[ "$GUEST_SUDO" == sudo ]]; then echo "systemctl start docker"; else echo "rc-service docker start"; fi; }
base_image() { if [[ "$RIG_OS" == flatcar && "${ROLE:-}" != kit ]]; then echo "$BASE_DIR/current-flatcar.qcow2"; else echo "$BASE_DIR/current.qcow2"; fi; }
SSH_OPTS=(-i "$SSH_DIR/id_lab" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
log() { printf '[%s] %s\n' "${NODE_NAME:-rig}" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "${NODE_NAME:-rig}" "$*" >&2; exit 1; }
reg_host()   { echo "${RIG_REGISTRY%%/*}"; }
reg_region() { reg_host | sed -n 's#.*\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com#\1#p'; }
# ECR token via the credential helper (reads AWS_PROFILE / AWS_ACCESS_KEY_ID / ~/.aws)
reg_token() { echo "$(reg_host)" | docker-credential-ecr-login get 2>/dev/null | jq -r .Secret; }
# node identity from NODE_KEY (RIG_APP, RIG_DNS_1, RIG_GW_2, RIG_KIT_DEMO ...)
node_var() { eval "echo \"\${${NODE_KEY}_$1:-}\""; }
# Node identity: derived from NODE_KEY so helpers run via `docker exec` (which does
# not see the entrypoint's exports) resolve the same values.
if [[ -n "${NODE_KEY:-}" ]]; then
    : "${NODE_NAME:=$(node_var NAME)}"; : "${NODE_IP:=$(node_var IP)}"; : "${NODE_MAC:=$(node_var MAC)}"
    : "${NODE_FQDN:=$(node_var FQDN)}"; : "${AUX_IP:=$(node_var AUX_IP)}"
    export NODE_NAME NODE_IP NODE_MAC NODE_FQDN AUX_IP
fi
