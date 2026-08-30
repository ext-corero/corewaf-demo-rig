#!/usr/bin/env bash
# rig-node entrypoint: turn this container into the hypervisor for ONE rig VM.
set -euo pipefail
source /usr/local/bin/rig-lib.sh
# Dispatch: `rig-init`, `cli` (idle), any helper verb (rig, vm-ssh, ...), or a shell.
case "${1:-node}" in
  node)     ;;
  cli)      exec sleep infinity ;;
  sh|bash)  exec "$@" ;;
  *)        command -v "$1" >/dev/null 2>&1 && exec "$@"; die "unknown command: $1" ;;
esac

: "${ROLE:?ROLE (app|dns|gw|obs|kit)}"; : "${NODE_KEY:?NODE_KEY (RIG_APP, RIG_DNS_1, ...)}"
# NODE_* come from rig-lib.sh (derived from NODE_KEY)
[[ -n "$NODE_IP" && -n "$NODE_MAC" && -n "$NODE_FQDN" ]] || die "inventory.env has no ${NODE_KEY}_IP/_MAC/_FQDN"
RAM_MB="${RAM_MB:-2048}"; VCPUS="${VCPUS:-2}"

# ---- fail fast: KVM is required ----
[[ -w /dev/kvm ]] || die "KVM is required: /dev/kvm is not exposed to this container.
  Linux : enable VT-x/AMD-V in firmware; the compose file passes --device /dev/kvm.
  WSL2  : %UserProfile%\\.wslconfig -> [wsl2] nestedVirtualization=true, then 'wsl --shutdown' and restart Docker Desktop."
[[ -e /dev/net/tun ]] || die "/dev/net/tun missing (needs devices: /dev/net/tun + cap NET_ADMIN)"
[[ -s "$BASE_DIR/current.qcow2" ]] || die "base image missing — rig-init did not run"
[[ -s "$AUTH_DIR/docker-config.json" && -s "$SSH_DIR/id_lab" ]] || die "rig-init outputs missing"

# ---- network: container becomes an L2 switch; the guest owns the docker IP ----
GW="$(ip -4 route show default | awk '{print $3; exit}')"; MTU="$(cat /sys/class/net/eth0/mtu)"; export MTU
ip addr flush dev eth0
# The docker endpoint MAC (compose `mac_address` = inventory MAC) is what the network
# fabric knows this endpoint by, and the guest NIC uses exactly that MAC: Docker
# Desktop's data path delivers by endpoint MAC/IP rather than learning like a Linux
# bridge, so a foreign guest MAC only half-works there. eth0 itself moves to a
# throwaway MAC so the bridge never sees the guest's address as a local port address.
INV_MAC="$NODE_MAC"; EP_MAC="$(cat /sys/class/net/eth0/address)"
if [[ "$EP_MAC" != "$NODE_MAC" ]]; then
    log "net: endpoint MAC $EP_MAC != inventory $NODE_MAC — guest uses the endpoint MAC (compose mac_address missing?)"; NODE_MAC="$EP_MAC"
fi
ip link set eth0 down; ip link set eth0 address "$(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"; ip link set eth0 up
ip link add br0 type bridge 2>/dev/null || true; ip link set br0 up
ip link set eth0 master br0
ip tuntap add tap0 mode tap 2>/dev/null || true; ip link set tap0 master br0 up
ip addr add "$AUX_IP/24" dev br0 2>/dev/null || true
ip route replace default via "$GW"
log "net: guest $NODE_IP/$NODE_MAC via tap0<->br0<->eth0, container aux $AUX_IP, gw $GW, mtu $MTU"
# Bootstrap resolver for the guest: forward DNS on the aux IP to whatever resolver
# Docker gave THIS container (its embedded DNS -> the host's/VPN's resolver). Public
# resolvers (8.8.8.8) are blocked on many corporate VPNs and Docker Desktop hosts;
# the container's own resolver always works wherever `docker pull` works.
UPSTREAM_DNS="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"; UPSTREAM_DNS="${UPSTREAM_DNS:-127.0.0.11}"
socat UDP4-RECVFROM:53,bind="$AUX_IP",reuseaddr,fork UDP4-SENDTO:"$UPSTREAM_DNS":53 &
socat TCP4-LISTEN:53,bind="$AUX_IP",reuseaddr,fork TCP4:"$UPSTREAM_DNS":53 &
log "net: bootstrap resolver $AUX_IP:53 -> $UPSTREAM_DNS"

# ---- disk: overlay on the shared base (generation-pinned path) ----
mkdir -p "$STATE_DIR/share" "$STATE_DIR/tpm"; rm -f "$STATE_DIR/share/ready"
BASE="$(readlink -f "$BASE_DIR/current.qcow2")"
if [[ ! -s "$STATE_DIR/disk.qcow2" ]]; then
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$STATE_DIR/disk.qcow2" "${DISK_SIZE:-16G}"; log "disk: new overlay on $(basename "$BASE")"
fi

# ---- seed ----
IID="$(seed.sh /run/seed)"; log "seed: instance-id $IID"

# ---- TPM (kits) ----
TPM_ARGS=()
if [[ "${TPM:-0}" == 1 ]]; then
    swtpm socket --tpm2 --tpmstate dir="$STATE_DIR/tpm" --ctrl type=unixio,path=/run/swtpm.sock --daemon --log level=1
    TPM_ARGS=(-chardev socket,id=chrtpm,path=/run/swtpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
fi
FS_ARGS=(-virtfs "local,path=$RIG_ROOT/v2,mount_tag=v2cfg,security_model=none,readonly=on"
         -virtfs "local,path=$SECRETS_DIR,mount_tag=secrets,security_model=none"
         -virtfs "local,path=$CA_DIR,mount_tag=rigca,security_model=none,readonly=on"
         -virtfs "local,path=$STATE_DIR/share,mount_tag=nodestate,security_model=none")
KITSHIM=/rig/kit-shim; [[ -d "$KITSHIM" ]] || KITSHIM=/rig/v2/kit-shim
[[ "$ROLE" == kit && -d "$KITSHIM" ]] && FS_ARGS+=(-virtfs "local,path=$KITSHIM,mount_tag=kitshim,security_model=none,readonly=on")
[[ "${RIG_MODE:-pull}" == source && -d /rig/workspace ]] && FS_ARGS+=(-virtfs "local,path=/rig/workspace,mount_tag=workspace,security_model=none,readonly=on")

# ---- machine identity: deterministic per node (from the inventory MAC) ----
# Guests (the kit's network-loader in particular) fingerprint the machine from DMI;
# QEMU's defaults are identical for every VM, so give each node its own stable
# UUID + serial — unique per slot, unchanged across restarts/re-stagings.
NODE_UUID="$(printf '%s' "corewaf-rig:$INV_MAC" | sha256sum | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
# ---- QEMU ----
log "qemu: ${VCPUS} vcpu, ${RAM_MB} MB, uuid $NODE_UUID"
qemu-system-x86_64 -enable-kvm -machine q35,accel=kvm -cpu host -smp "$VCPUS" -m "$RAM_MB" \
  -uuid "$NODE_UUID" -smbios "type=1,manufacturer=CoreWAF,product=demo-rig-node,serial=$NODE_NAME,uuid=$NODE_UUID" \
  -display none -vga none -monitor none \
  -chardev stdio,id=con0,signal=off -serial chardev:con0 \
  -serial unix:/run/ttyS1.sock,server=on,wait=off \
  -qmp unix:/run/qmp.sock,server=on,wait=off \
  -drive file="$STATE_DIR/disk.qcow2",if=virtio,format=qcow2,cache=writeback,discard=unmap \
  -drive file=/run/seed/seed.iso,media=cdrom,format=raw,readonly=on \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac="$NODE_MAC" \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  "${FS_ARGS[@]}" "${TPM_ARGS[@]}" &
QPID=$!

qmp() { printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" | socat -T3 - unix-connect:/run/qmp.sock >/dev/null 2>&1 || true; }
shutdown_vm() {
    log "stop: ACPI powerdown"; qmp system_powerdown
    for _ in $(seq 1 20); do kill -0 "$QPID" 2>/dev/null || return 0; sleep 1; done
    log "stop: guest still up, ssh poweroff"; vm-ssh 'doas poweroff' >/dev/null 2>&1 || true
    for _ in $(seq 1 70); do kill -0 "$QPID" 2>/dev/null || return 0; sleep 1; done
    log "stop: forcing quit"; qmp quit; sleep 2; kill -9 "$QPID" 2>/dev/null || true
}
trap 'shutdown_vm; exit 0' TERM INT

# ---- post-boot: start the role's stack once the guest is reachable ----
(
  for _ in $(seq 1 180); do nc -z -w2 "$NODE_IP" 22 >/dev/null 2>&1 && break; sleep 2; done
  nc -z -w2 "$NODE_IP" 22 >/dev/null 2>&1 || { log "guest never opened ssh"; exit 0; }
  log "guest up (ssh)"
  if [[ "${NO_STACK:-0}" != 1 && "$ROLE" != kit ]]; then
      if [[ "$ROLE" == gw || "$ROLE" == obs ]]; then
          for _ in $(seq 1 120); do [[ -f "$SECRETS_DIR/tunnel-gw/root.crt" ]] && break; sleep 5; done
          [[ -f "$SECRETS_DIR/tunnel-gw/root.crt" ]] || log "warning: app-1 never published tunnel-gw secrets; starting anyway"
      fi
      log "stack: starting compose/$ROLE.yml in the guest"
      if vm-stack; then touch "$STATE_DIR/share/ready"; log "stack: up"; else log "stack: FAILED (rerun: docker compose exec $NODE_NAME vm-stack)"; fi
  fi
) &
wait "$QPID" || true
log "qemu exited"
