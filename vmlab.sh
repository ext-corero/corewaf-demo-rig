#!/usr/bin/env bash
# v2/vmlab.sh — infra-VM driver for the demo rig multi-VM topology.
#
# Distinct from demo-rig/vm/vmlab.sh (which provisions the external KIT and
# stays as-is). This one boots the *infrastructure* VMs — app / dns-N / gw-N —
# onto the routed `corewaf-rig` network, maps the host workspace + v2 config +
# shared-secrets + CA in via virtiofs, points each VM's resolver at the dns
# VMs, trusts the rig root CA, and (optionally) brings the role's docker stack
# up from the mapped source.
#
# Everything role-specific is derived from v2/inventory.env — no IPs/FQDNs are
# hardcoded here.
#
# Verbs: net-up, net-down, create <role> [n], stack <role> [n], exec, destroy,
#        list. (`up.sh` orchestrates create+stack across all roles.)

set -euo pipefail

: "${LIBVIRT_DEFAULT_URI:=qemu:///system}"
export LIBVIRT_DEFAULT_URI

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # repo root
RIG_DIR="$HERE"                              # repo root
WORKSPACE="$(cd "$RIG_DIR/.." && pwd)"                         # repo root (corewaf-workspace)

# shellcheck disable=SC1091
source "$HERE/inventory.env"

LAB_DIR="${LAB_DIR:-$HOME/vm-lab}"
INSTANCES="$LAB_DIR/instances"
SEEDS="$LAB_DIR/seeds"
SSH_KEY="$LAB_DIR/id_lab"
BASE_IMG="${V2_BASE_IMG:-$RIG_DIR/.cache/corewaf-kit-base.qcow2}"

SHARED_SECRETS="$RIG_DIR/.v2/shared-secrets"
DISK_SIZE="${DISK_SIZE:-16G}"

mkdir -p "$INSTANCES" "$SEEDS" "$SHARED_SECRETS"
[[ -f "$SSH_KEY" ]] || ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C lab >/dev/null

die() { echo "error: $*" >&2; exit 1; }

ssh_opts=( -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o LogLevel=ERROR -o ConnectTimeout=5 )

# ---- role → identity resolution (from inventory.env) -----------------------
# Usage: resolve_role app | resolve_role dns 1 | resolve_role gw 2
# Exports: R_NAME R_IP R_FQDN R_MAC R_RAM R_ROLE
resolve_role() {
    local role="$1" idx="${2:-}"
    local key
    case "$role" in
        app) key="RIG_APP"; R_RAM="${V2_APP_RAM_MB:-4096}" ;;
        dns) key="RIG_DNS_${idx}"; R_RAM="${V2_DNS_RAM_MB:-2048}" ;;
        gw)  key="RIG_GW_${idx}";  R_RAM="${V2_GW_RAM_MB:-2048}"  ;;
        # observability VM (loki+mimir+alertmanager+grafana) — wants more RAM.
        # Single instance: fixed key (like app), so `exec obs '<cmd>'` doesn't
        # mis-parse the command as an index.
        obs) key="RIG_OBS_1"; R_RAM="${V2_OBS_RAM_MB:-4096}" ;;
        # 'secrets' is not its own VM: the vmsecd stack (compose/secrets.yml)
        # is deployed ONTO a dns VM, so it resolves to that dns VM's identity.
        # cmd_stack then picks compose/secrets.yml from R_ROLE.
        secrets) key="RIG_DNS_${idx}"; R_RAM="${V2_DNS_RAM_MB:-2048}" ;;
        *) die "unknown role: $role (app|dns|gw|obs|secrets)" ;;
    esac
    R_NAME="$(eval "echo \${${key}_NAME:-}")"
    R_IP="$(eval "echo \${${key}_IP:-}")"
    R_FQDN="$(eval "echo \${${key}_FQDN:-}")"
    R_MAC="$(eval "echo \${${key}_MAC:-}")"
    R_ROLE="$role"
    R_IDX="$idx"
    R_KEY="$key"          # inventory prefix, e.g. RIG_GW_1 — used to read per-node extras
    [[ -n "$R_NAME" && -n "$R_IP" && -n "$R_MAC" ]] || die "inventory missing $key (role=$role idx=$idx)"
}

vm_ip() { virsh domifaddr "$1" --source agent 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -n1; }

# ---- network ---------------------------------------------------------------
cmd_net_up() {
    if virsh net-info "$RIG_NET_NAME" &>/dev/null; then
        [[ "$(virsh net-info "$RIG_NET_NAME")" =~ Active:[[:space:]]+yes ]] || virsh net-start "$RIG_NET_NAME"
        echo "network $RIG_NET_NAME present"
    else
        virsh net-define "$HERE/net/corewaf-rig.xml"
        virsh net-start "$RIG_NET_NAME"
        virsh net-autostart "$RIG_NET_NAME"
        echo "network $RIG_NET_NAME defined + started"
    fi
}
cmd_net_down() { virsh net-destroy "$RIG_NET_NAME" 2>/dev/null || true; }

# ---- cloud-init seed -------------------------------------------------------
# Common first-boot for every infra VM: mount the four virtiofs shares, point
# resolv.conf at the dns VMs, trust the rig root CA. NO /etc/hosts seeding —
# rig.internal resolves only via the dns VMs (self-assembly under test).
write_seed() {
    local name="$1"
    local pubkey; pubkey="$(<"${SSH_KEY}.pub")"
    local resolvers="" ns
    for ns in $RIG_RESOLVERS; do resolvers+="nameserver $ns\n"; done
    # Bootstrap/last-resort upstream (only used when both dns VMs time out).
    [[ -n "${RIG_BOOTSTRAP_RESOLVER:-}" ]] && resolvers+="nameserver $RIG_BOOTSTRAP_RESOLVER\n"

    # ---- per-node identity (the rig's stand-in for a Terraform-stamped node) -
    # SHORT is the hostname (gw-1); /etc/corewaf-bootstrap holds the qualified
    # truth every container reads (env_file). NO per-instance identity is
    # injected at `stack` time — the booted node IS the source of truth.
    local short="${R_FQDN%.$RIG_DOMAIN}"
    local bootstrap=""
    bootstrap+="NODE_NAME=$short\n"
    bootstrap+="FQDN=$R_FQDN\n"
    bootstrap+="ZONE=$RIG_DOMAIN\n"
    bootstrap+="NODE_IP=$R_IP\n"
    # gw-only: the IP-pool partition this gateway owns (topology assignment, not
    # identity — in prod the IPAM coordinator hands this out; here the inventory
    # pre-partitions it). Lives in the same node file for one read path.
    if [[ "$R_ROLE" == "gw" ]]; then
        local cidr addr
        cidr="$(eval "echo \${${R_KEY}_IPAM_CIDR:-}")"
        addr="$(eval "echo \${${R_KEY}_WG_ADDR:-}")"
        [[ -n "$cidr" ]] && bootstrap+="IPAM_CIDR=$cidr\n"
        [[ -n "$addr" ]] && bootstrap+="WG_ADDR=$addr\n"
    fi

    cat >"$SEEDS/$name-user-data" <<EOF
#cloud-config
output: { all: '| tee -a /var/log/cloud-init-output.log /dev/console' }
hostname: $short
ssh_pwauth: false
disable_root: true
package_update: false
users:
  - name: alpine
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/sh
    ssh_authorized_keys: [ $pubkey ]
bootcmd:
  - sed -i 's|/sbin/agetty -[^ ]* [^ ]* |/sbin/getty |g; s|/sbin/agetty|/sbin/getty|g' /etc/inittab
  - kill -HUP 1
write_files:
  - path: /etc/resolv.conf
    content: |
$(printf '%b' "$resolvers" | sed 's/^/      /')
      search $RIG_DOMAIN
  # Per-node truth, sourced by every container via compose env_file. The one
  # place a service learns its FQDN/name — no string is passed at `stack` time.
  - path: /etc/corewaf-bootstrap
    permissions: '0644'
    content: |
$(printf '%b' "$bootstrap" | sed 's/^/      /')
$(registry_auth_files)
runcmd:
  - modprobe virtiofs || true
  - modprobe 9pnet_virtio || true
  - mkdir -p $RIG_WORKSPACE_MOUNT /opt/v2 /opt/shared-secrets /opt/rig-ca
  - mount -t virtiofs workspace $RIG_WORKSPACE_MOUNT 2>/dev/null || rmdir $RIG_WORKSPACE_MOUNT || true
  - mount -t virtiofs v2cfg /opt/v2 || true
  - mount -t virtiofs secrets /opt/shared-secrets || true
  - mount -t virtiofs rigca /opt/rig-ca || true
  - sh -c 'for t in "v2cfg /opt/v2" "secrets /opt/shared-secrets" "rigca /opt/rig-ca"; do echo "\$t virtiofs defaults 0 0" >> /etc/fstab; done; [ -d $RIG_WORKSPACE_MOUNT ] && echo "workspace $RIG_WORKSPACE_MOUNT virtiofs defaults,nofail 0 0" >> /etc/fstab || true'
  - mkdir -p /usr/local/share/ca-certificates
  - cp /opt/rig-ca/root_ca.crt /usr/local/share/ca-certificates/corewaf-rig-root.crt
  - update-ca-certificates || true
  - addgroup alpine docker || true
  - rc-update add docker default || true
  - rc-service docker start || true
final_message: "infra VM $name ready (uptime: \$UPTIME s)"
EOF
    cat >"$SEEDS/$name-meta-data" <<EOF
instance-id: $name
local-hostname: $short
EOF
    xorriso -as mkisofs -quiet -V cidata -o "$SEEDS/$name-seed.iso" -J -r \
        -graft-points "user-data=$SEEDS/$name-user-data" "meta-data=$SEEDS/$name-meta-data"
    chmod 600 "$SEEDS/$name-user-data" "$SEEDS/$name-seed.iso"
}

# ---- registry auth for the VM's docker ---------------------------------------
# The rig pulls its images from the CoreWAF registry (ECR, see images.env). The
# host mints a registry token with the operator's AWS identity (AWS_PROFILE /
# AWS_ACCESS_KEY_ID..., any user in group corewaf-ecr-pull) and cloud-init drops
# it into /root/.docker/config.json — root is what `doas docker compose` runs as.
# ECR tokens last 12h; `stack` pulls right after boot, so that is enough today.
# (The base image will carry docker-credential-ecr-login + the creds themselves
# so long-running VMs can re-pull — follow-up.) RIG_MODE=source needs none of it.
registry_auth_files() {
    [[ "${RIG_MODE:-pull}" == source ]] && return 0
    local host; host="$(sed -n 's#^RIG_REGISTRY=\([^/]*\)/.*#\1#p' "$HERE/images.env")"
    [[ -n "$host" ]] || die "images.env: RIG_REGISTRY missing"
    local region; region="$(echo "$host" | sed -n 's#.*\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com#\1#p')"
    local tok
    tok="$(aws ecr get-login-password --region "$region" 2>/dev/null)" \
        || die "cannot mint a registry token for $host — set AWS_PROFILE (or AWS_ACCESS_KEY_ID/SECRET) to a CoreWAF registry user (group corewaf-ecr-pull), or use RIG_MODE=source"
    local auth; auth="$(printf 'AWS:%s' "$tok" | base64 -w0)"
    cat <<EOF2
  - path: /root/.docker/config.json
    permissions: '0600'
    content: |
      {"auths": {"$host": {"auth": "$auth"}}}
EOF2
}

# ---- create a VM -----------------------------------------------------------
cmd_create() {
    resolve_role "$@"
    local name="$R_NAME" disk="$INSTANCES/$R_NAME.qcow2"
    if virsh dominfo "$name" &>/dev/null; then
        if virsh domstate "$name" | grep -q running; then
            echo "$name already running"; return 0
        fi
        echo -n "[$name] exists, starting "
        virsh start "$name" >/dev/null
        for _ in $(seq 1 90); do
            ssh "${ssh_opts[@]}" "alpine@$R_IP" true 2>/dev/null && { echo " up"; return 0; }
            echo -n "."; sleep 2
        done
        die "$name never reached ssh at $R_IP"
    fi
    [[ -f "$BASE_IMG" ]] || die "base image missing: $BASE_IMG (build with scripts/build-kit-base.sh)"

    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMG" "$disk" "$DISK_SIZE"
    write_seed "$name"
    # The full workspace is mapped in ONLY for RIG_MODE=source (builds from source).
    # In the default pull mode the VM sees just /opt/v2 (this repo), the shared
    # secrets dir and the rig CA — no dependency on a corewaf-workspace checkout.
    local WS_FS=()
    if [[ "${RIG_MODE:-pull}" == source ]]; then
        [[ -d "$WORKSPACE/waf" ]] || die "RIG_MODE=source needs a corewaf-workspace checkout at $WORKSPACE"
        WS_FS=(--filesystem "driver.type=virtiofs,source.dir=$WORKSPACE,target.dir=workspace,readonly=on")
    fi

    /usr/bin/python3 /usr/bin/virt-install \
        --name "$name" \
        --memory "$R_RAM" --vcpus "${V2_VCPUS:-2}" \
        --memorybacking access.mode=shared,source.type=memfd \
        --disk "path=$disk,format=qcow2,bus=virtio" \
        --disk "path=$SEEDS/$name-seed.iso,device=cdrom" \
        --os-variant alpinelinux3.20 \
        --network "network=$RIG_NET_NAME,model=virtio,mac=$R_MAC" \
        "${WS_FS[@]}" \
        --filesystem "driver.type=virtiofs,source.dir=$HERE,target.dir=v2cfg,readonly=on" \
        --filesystem "driver.type=virtiofs,source.dir=$SHARED_SECRETS,target.dir=secrets" \
        --filesystem "driver.type=virtiofs,source.dir=$RIG_DIR/.v2/ca,target.dir=rigca,readonly=on" \
        --graphics none --console pty,target_type=serial \
        --import --noautoconsole >/dev/null

    echo -n "[$name] waiting for ssh @ $R_IP "
    for _ in $(seq 1 90); do
        ssh "${ssh_opts[@]}" "alpine@$R_IP" true 2>/dev/null && { echo " up"; return 0; }
        echo -n "."; sleep 2
    done
    die "$name never reached ssh at $R_IP"
}

# ---- bring the role's docker stack up (from the mapped source) -------------
cmd_stack() {
    resolve_role "$@"
    # NO per-instance identity is injected here. The booted node is the source
    # of truth: compose reads ${HOSTNAME} (the node's own hostname, evaluated on
    # the VM) for the container hostname, and `env_file: /etc/corewaf-bootstrap`
    # (written by cloud-init) for $FQDN / $NODE_NAME / per-gw $IPAM_CIDR.
    #
    # Default: images are PULLED from the registry pinned in images.env (the VM
    # authenticates with the docker auth cloud-init wrote — see write_seed).
    # RIG_MODE=source: build from the sibling corewaf-workspace mapped at
    # $RIG_WORKSPACE_MOUNT via compose/build/<role>.yml (developer path).
    local files="-f compose/$R_ROLE.yml" build=""
    if [[ "${RIG_MODE:-pull}" == source ]]; then
        files="$files -f compose/build/$R_ROLE.yml"; build="--build"
    fi
    ssh "${ssh_opts[@]}" "alpine@$R_IP" \
        "doas rc-service docker start >/dev/null 2>&1 || true; \
         doas sh -c 'cd /opt/v2 && \
           set -a; . /etc/corewaf-bootstrap; [ -f /opt/shared-secrets/rig-secrets.env ] && . /opt/shared-secrets/rig-secrets.env; set +a; \
           HOSTNAME=\"\$(hostname)\" RIG_SRC=$RIG_WORKSPACE_MOUNT docker compose --env-file inventory.env --env-file images.env $files up $build -d'"
}

cmd_exec() { resolve_role "$1" "${2:-}"; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && shift || true
             ssh "${ssh_opts[@]}" "alpine@$R_IP" "$@"; }
cmd_destroy() { resolve_role "$@"; virsh destroy "$R_NAME" 2>/dev/null || true
                virsh undefine "$R_NAME" --remove-all-storage --nvram 2>/dev/null || true
                rm -f "$SEEDS/$R_NAME-seed.iso" "$SEEDS/$R_NAME-user-data" "$SEEDS/$R_NAME-meta-data"; }
cmd_list() { for n in $(virsh list --all --name | grep '^rig2-'); do printf "%-16s %s\n" "$n" "$(vm_ip "$n")"; done; }

case "${1:-}" in
    net-up)   cmd_net_up ;;
    net-down) cmd_net_down ;;
    create)   shift; cmd_create "$@" ;;
    stack)    shift; cmd_stack  "$@" ;;
    exec)     shift; cmd_exec   "$@" ;;
    destroy)  shift; cmd_destroy "$@" ;;
    list)     cmd_list ;;
    *) echo "usage: $0 {net-up|net-down|create <role> [n]|stack <role> [n]|exec <role> [n] <cmd>|destroy <role> [n]|list}  (role: app|dns|gw|obs|secrets)" >&2; exit 2 ;;
esac
