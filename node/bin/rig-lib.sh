#!/usr/bin/env bash
# rig-lib.sh — shared by the node image scripts. Expects the rig env
# (inventory.env + images.env, loaded by compose env_file) in the environment.
RIG_ROOT=/rig                      # bind: repo checkout (ro) -> exported to guests as /opt/v2
BASE_DIR=/rig/base                 # volume rig-base
CA_DIR=/rig/ca                     # volume rig-ca
SECRETS_DIR=/rig/shared-secrets    # volume rig-shared-secrets (rw; app writes, gw/obs read)
AUTH_DIR=/rig/auth                 # volume rig-auth  (docker-config.json)
SSH_DIR=/rig/ssh                   # volume rig-ssh   (id_lab, id_lab.pub)
STATE_DIR=/state                   # per-node volume (disk.qcow2, tpm/, share/)
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
