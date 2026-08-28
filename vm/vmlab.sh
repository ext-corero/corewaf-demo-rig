#!/usr/bin/env bash
# vmlab.sh — libvirt + swtpm + virtio-9p client-simulation harness
# for the demo rig's tunnel-v2 plane.
#
# Ported from waf/tunnel-gateway/cicd/fixture/multi-vm/vmlab.sh.
# The fixture and the rig share libvirt state under $HOME/vm-lab/
# (same prepared base image + SSH key); VM names launched from
# here are auto-prefixed with `rig-` to avoid collisions with the
# fixture's `kit1`/`kit2`/...
#
# Differences vs the fixture vmlab.sh:
#   * /etc/hosts inside the VM maps `corewaf.localhost` to the
#     libvirt-bridge gateway (not the fixture's `caddy gw-a gw-b ...`).
#   * No `backend-test 172.31.0.20` entry (no backend-test in the rig).
#   * KIT_SHIM defaults to `demo-rig/vm/kit-shim/` (this directory).
#   * VM name auto-prefix `rig-` keeps fixture + rig instances disjoint
#     in libvirt's flat namespace.
#
# Prerequisite: the fixture's prep-host.sh and prepare-base.sh have
# been run at least once (creates $HOME/vm-lab/, the SSH key, and
# the prepared Alpine base image). Re-running them is a no-op.
#
# Five verbs: create, exec, scp, console, destroy, list.

set -euo pipefail

: "${LIBVIRT_DEFAULT_URI:=qemu:///system}"
export LIBVIRT_DEFAULT_URI


# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/host.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/inventory.env"
RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="$(host_lab_dir)"
read -r -a VIRT_INSTALL <<<"$(host_virt_install)"
INSTANCES="$LAB_DIR/instances"
SEEDS="$LAB_DIR/seeds"
SSH_KEY="$LAB_DIR/id_lab"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Kit VMs boot from the SAME base image as the infra VMs (scripts/fetch-base.sh).
BASE_IMG="${KIT_BASE_IMG:-$RIG_ROOT/.cache/corewaf-rig-base.qcow2}"
USING_PREPARED=1
KIT_SHIM="${KIT_SHIM:-$SCRIPT_DIR/kit-shim}"

# Optional registry auth for the kit VM's docker (root): pass the full
# /root/.docker/config.json content in DOCKER_AUTH_JSON (kit-prep/kit-up do,
# from lib/registry.sh). Empty = no registry auth written.
docker_auth_write_files() {
    [[ -n "${DOCKER_AUTH_JSON:-}" ]] || return 0
    cat <<EOF2
write_files:
  - path: /root/.docker/config.json
    permissions: '0600'
    content: |
      ${DOCKER_AUTH_JSON}
EOF2
}

# Kit VMs join the rig network (DHCP range) — same L2 as the gateways.
NETWORK="${NETWORK:-$RIG_NET_NAME}"
RAM_MB="${RAM_MB:-1024}"
VCPUS="${VCPUS:-1}"
DISK_SIZE="${DISK_SIZE:-12G}"

# Libvirt default-NAT bridge gateway = host as seen by the VM.
# Override only if your libvirt network is remapped.
RIG_HOST_IP="${RIG_HOST_IP:-192.168.122.1}"

# Auto-prefix VM names so they don't collide with the fixture's.
# Caller passes `demo`, libvirt sees `rig-demo`.
NAME_PREFIX="${NAME_PREFIX:-rig-}"

mkdir -p "$INSTANCES" "$SEEDS"
[[ -f "$SSH_KEY" ]] || { ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C lab >/dev/null; setfacl -b "$SSH_KEY" 2>/dev/null || true; chmod 600 "$SSH_KEY"; }

die() { echo "error: $*" >&2; exit 1; }

prefixed() {
    local n="$1"
    case "$n" in
        "${NAME_PREFIX}"*) printf '%s' "$n" ;;
        *) printf '%s%s' "$NAME_PREFIX" "$n" ;;
    esac
}

ssh_opts=(
    -i "$SSH_KEY"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

vm_ip() {
    local name="$1"
    virsh domifaddr "$name" 2>/dev/null \
        | awk '/ipv4/ {print $4}' \
        | cut -d/ -f1 \
        | head -n1
}

cmd_create() {
    local raw="${1:?usage: vmlab.sh create <name>}"
    local name; name=$(prefixed "$raw")
    local disk="$INSTANCES/$name.qcow2"
    local seed="$SEEDS/$name-seed.iso"

    virsh dominfo "$name" &>/dev/null && die "VM $name already exists"
    [[ -f "$BASE_IMG" ]] || die "base image missing: $BASE_IMG (run fixture/multi-vm/prep-host.sh + prepare-base.sh first)"
    [[ -d "$KIT_SHIM" ]] || die "kit-shim dir missing: $KIT_SHIM"

    qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$BASE_IMG")" "$disk" "$DISK_SIZE"

    local pubkey; pubkey=$(<"${SSH_KEY}.pub")
    if (( USING_PREPARED )); then
        cat >"$SEEDS/$name-user-data" <<EOF
#cloud-config
output:
  all: '| tee -a /var/log/cloud-init-output.log /dev/console'
hostname: $name
ssh_pwauth: false
disable_root: true
package_update: false
users:
  - name: alpine
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/sh
    ssh_authorized_keys:
      - $pubkey
$(docker_auth_write_files)
bootcmd:
  - sed -i 's|/sbin/agetty -[^ ]* [^ ]* |/sbin/getty |g; s|/sbin/agetty|/sbin/getty|g' /etc/inittab
  - kill -HUP 1
runcmd:
  - modprobe 9pnet_virtio || true
  - modprobe tpm_crb || true
  - mkdir -p /opt/kit-shim
  - mount -t 9p -o trans=virtio,version=9p2000.L,cache=none,ro kitshim /opt/kit-shim || true
  - sh -c 'echo "kitshim /opt/kit-shim 9p trans=virtio,version=9p2000.L,cache=none,ro 0 0" >> /etc/fstab'
  - chown alpine:alpine /home/alpine || true
final_message: "VM $name ready (uptime: \$UPTIME s)"
EOF
    else
        cat >"$SEEDS/$name-user-data" <<EOF
#cloud-config
output:
  all: '| tee -a /var/log/cloud-init-output.log /dev/console'
hostname: $name
ssh_pwauth: false
disable_root: true
package_update: true
packages:
  - sudo
  - curl
  - openssl
  - wireguard-tools
  - tpm2-tools
  - iproute2
  - iptables
  - bind-tools
  - linux-lts
  - tpm2-tss-tcti-device
users:
  - name: alpine
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/sh
    ssh_authorized_keys:
      - $pubkey
$(docker_auth_write_files)
bootcmd:
  - sed -i 's|/sbin/agetty -[^ ]* [^ ]* |/sbin/getty |g; s|/sbin/agetty|/sbin/getty|g' /etc/inittab
  - kill -HUP 1
runcmd:
  - modprobe 9pnet_virtio || true
  - modprobe tpm_crb || true
  - sh -c 'printf "9pnet_virtio\ntpm_crb\n" >> /etc/modules'
  - mkdir -p /opt/kit-shim
  - mount -t 9p -o trans=virtio,version=9p2000.L,cache=none,ro kitshim /opt/kit-shim || true
  - sh -c 'echo "kitshim /opt/kit-shim 9p trans=virtio,version=9p2000.L,cache=none,ro 0 0" >> /etc/fstab'
  - chown alpine:alpine /home/alpine || true
  - apk del linux-virt
power_state:
  delay: now
  mode: reboot
  message: "Switching to linux-lts kernel"
  condition: True
final_message: "VM $name ready (uptime: \$UPTIME s)"
EOF
    fi
    cat >"$SEEDS/$name-meta-data" <<EOF
instance-id: $name
local-hostname: $name
EOF

    xorriso -as mkisofs -quiet -V cidata -o "$seed" -J -r \
        -graft-points \
            "user-data=$SEEDS/$name-user-data" \
            "meta-data=$SEEDS/$name-meta-data"
    chmod 600 "$SEEDS/$name-user-data" "$seed"     # may carry a registry token
    # Private to us + readable by the qemu user that boots the VM (libvirt runs
    # qemu unprivileged; without this the seed is unreadable and cloud-init never runs).
    setfacl -m "u:$(host_qemu_user):r" "$seed" 2>/dev/null || chmod 644 "$seed"

    "${VIRT_INSTALL[@]}" \
        --name "$name" \
        --memory "$RAM_MB" --vcpus "$VCPUS" \
        --disk "path=$disk,format=qcow2,bus=virtio" \
        --disk "path=$seed,device=cdrom" \
        $(host_osinfo_arg) \
        --network "network=$NETWORK,model=virtio" \
        --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
        --filesystem "$KIT_SHIM,kitshim,readonly=on" \
        --graphics none \
        --console pty,target_type=serial \
        --import --noautoconsole >/dev/null

    echo -n "waiting for IP "
    local ip=""
    for _ in $(seq 1 60); do
        ip=$(vm_ip "$name")
        [[ -n "$ip" ]] && break
        echo -n "."; sleep 2
    done
    echo
    [[ -n "$ip" ]] || die "no IP for $name after 120s"

    if (( USING_PREPARED )); then
        echo -n "waiting for SSH "
        local poll_max=60
        local predicate="ssh_only"
    else
        echo -n "waiting for second boot (linux-lts) "
        local poll_max=180
        local predicate="kernel_lts"
    fi
    for _ in $(seq 1 "$poll_max"); do
        local kver
        kver=$(ssh "${ssh_opts[@]}" "alpine@$ip" "uname -r" 2>/dev/null || true)
        if [[ -n "$kver" ]]; then
            if [[ "$predicate" == "ssh_only" ]] || [[ "$kver" == *lts* ]]; then
                echo
                echo "$name $ip ($kver)"
                return 0
            fi
        fi
        echo -n "."
        sleep 2
    done
    die "VM $name never came up ($ip)"
}

cmd_exec() {
    local raw="${1:?usage: vmlab.sh exec <name> <cmd...>}"; shift
    local name; name=$(prefixed "$raw")
    local ip; ip=$(vm_ip "$name")
    [[ -n "$ip" ]] || die "no IP for $name"
    ssh "${ssh_opts[@]}" "alpine@$ip" "$@"
}

cmd_scp() {
    local raw="${1:?usage: vmlab.sh scp <name> <src> <dst>}"
    local src="${2:?usage: vmlab.sh scp <name> <src> <dst>}"
    local dst="${3:?usage: vmlab.sh scp <name> <src> <dst>}"
    local name; name=$(prefixed "$raw")
    local ip; ip=$(vm_ip "$name")
    [[ -n "$ip" ]] || die "no IP for $name"
    scp -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$src" "alpine@$ip:$dst"
}

cmd_console() {
    local raw="${1:?usage: vmlab.sh console <name>}"
    local name; name=$(prefixed "$raw")
    exec virsh console "$name"
}

cmd_destroy() {
    local raw="${1:?usage: vmlab.sh destroy <name>}"
    local name; name=$(prefixed "$raw")
    virsh destroy "$name" 2>/dev/null || true
    virsh undefine "$name" --remove-all-storage --nvram 2>/dev/null || true
    rm -f "$SEEDS/$name-seed.iso" "$SEEDS/$name-user-data" "$SEEDS/$name-meta-data"
}

cmd_list() {
    # Show only rig-prefixed domains; fixture VMs live in the same
    # libvirt namespace but aren't ours.
    for n in $(virsh list --all --name | grep -v '^$' | grep "^${NAME_PREFIX}"); do
        local ip; ip=$(vm_ip "$n")
        printf "%-20s %s\n" "$n" "${ip:-<no-ip>}"
    done
}

case "${1:-}" in
    create)  shift; cmd_create  "$@" ;;
    exec)    shift; cmd_exec    "$@" ;;
    scp)     shift; cmd_scp     "$@" ;;
    console) shift; cmd_console "$@" ;;
    destroy) shift; cmd_destroy "$@" ;;
    list)    shift; cmd_list    "$@" ;;
    *) echo "usage: $0 {create|exec|scp|console|destroy|list} ..." >&2; exit 2 ;;
esac
