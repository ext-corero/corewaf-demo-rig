#!/usr/bin/env bash
# qemu/run-node.sh <NODE_KEY> — boot one rig VM directly on the host (Model 3).
# Same disks/seeds/shares/identity as the container mode (shares node/bin code);
# networking = the libvirt NAT bridge (virbr-cwrig), guests directly addressable.
# Runs in the foreground; rig-qemu daemonizes it (setsid) with a pidfile + log.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_KEY="${1:?NODE_KEY (RIG_APP, RIG_DNS_1, ...)}"
source "$HERE/qemu/env.sh"
source "$RIG_LIB"
NODE="${NODE_NAME#rig2-}"; NODE="${NODE#rig-}"   # rig2-app-1 -> app-1, rig-kit-a -> kit-a
export STATE_DIR="$QDIR/state/$NODE" RUN_DIR="$QDIR/run/$NODE"
mkdir -p "$STATE_DIR/share" "$STATE_DIR/tpm" "$RUN_DIR"
rm -f "$STATE_DIR/share/ready"

BASE="$(readlink -f "$BASE_DIR/current.qcow2")"
[[ -s "$STATE_DIR/disk.qcow2" ]] || { qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$STATE_DIR/disk.qcow2" "${DISK_SIZE:-16G}"; log "disk: new overlay on $(basename "$BASE")"; }

export MTU=1500
IID="$(seed.sh "$RUN_DIR/seed")"; log "seed: instance-id $IID"

TPM_ARGS=()
if [[ "${TPM:-0}" == 1 ]]; then
    swtpm socket --tpm2 --tpmstate dir="$STATE_DIR/tpm" --ctrl type=unixio,path="$RUN_DIR/swtpm.sock" --daemon --log level=1
    TPM_ARGS=(-chardev "socket,id=chrtpm,path=$RUN_DIR/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
fi
FS_ARGS=(-virtfs "local,path=$V2_DIR,mount_tag=v2cfg,security_model=none,readonly=on"
         -virtfs "local,path=$SECRETS_DIR,mount_tag=secrets,security_model=mapped-xattr"
         -virtfs "local,path=$CA_DIR,mount_tag=rigca,security_model=none,readonly=on"
         -virtfs "local,path=$STATE_DIR/share,mount_tag=nodestate,security_model=none")
[[ "$ROLE" == kit && -d "$V2_DIR/kit-shim" ]] && FS_ARGS+=(-virtfs "local,path=$V2_DIR/kit-shim,mount_tag=kitshim,security_model=none,readonly=on")

NODE_UUID="$(printf '%s' "corewaf-rig:$NODE_MAC" | sha256sum | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
log "qemu: ${VCPUS:-2} vcpu, ${RAM_MB:-2048} MB, uuid $NODE_UUID, bridge virbr-cwrig"
qemu-system-x86_64 -enable-kvm -machine q35,accel=kvm -cpu host -smp "${VCPUS:-2}" -m "${RAM_MB:-2048}" \
  -uuid "$NODE_UUID" -smbios "type=1,manufacturer=CoreWAF,product=demo-rig-node,serial=$NODE_NAME,uuid=$NODE_UUID" \
  -display none -vga none -monitor none \
  -serial "file:$QDIR/log/$NODE.console" \
  -serial "unix:$RUN_DIR/ttyS1.sock,server=on,wait=off" \
  -qmp "unix:$RUN_DIR/qmp.sock,server=on,wait=off" \
  -drive "file=$STATE_DIR/disk.qcow2,if=virtio,format=qcow2,cache=writeback,discard=unmap" \
  -drive "file=$RUN_DIR/seed/seed.iso,media=cdrom,format=raw,readonly=on" \
  -netdev "tap,id=net0,ifname=tap-cw-$NODE,script=no,downscript=no" \
  -device "virtio-net-pci,netdev=net0,mac=$NODE_MAC" \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  "${FS_ARGS[@]}" "${TPM_ARGS[@]}" &
QPID=$!; echo "$QPID" > "$RUN_DIR/qemu.pid"

qmp() { printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" | socat -T3 - "unix-connect:$RUN_DIR/qmp.sock" >/dev/null 2>&1 || true; }
shutdown_vm() {
    log "stop: ACPI powerdown"; qmp system_powerdown
    for _ in $(seq 1 20); do kill -0 "$QPID" 2>/dev/null || return 0; sleep 1; done
    vm-ssh 'doas poweroff' >/dev/null 2>&1 || true
    for _ in $(seq 1 70); do kill -0 "$QPID" 2>/dev/null || return 0; sleep 1; done
    qmp quit; sleep 2; kill -9 "$QPID" 2>/dev/null || true
}
trap 'shutdown_vm; exit 0' TERM INT

( for _ in $(seq 1 150); do kill -0 "$QPID" 2>/dev/null || { log "qemu exited during boot — see this log above"; exit 1; }; nc -z -w2 "$NODE_IP" 22 >/dev/null 2>&1 && break; sleep 2; done
  if nc -z -w2 "$NODE_IP" 22 >/dev/null 2>&1; then
      log "guest up (ssh)"
      if [[ "$ROLE" == gw || "$ROLE" == obs ]]; then
          for _ in $(seq 1 120); do [[ -f "$SECRETS_DIR/tunnel-gw/root.crt" ]] && break; sleep 5; done
          [[ -f "$SECRETS_DIR/tunnel-gw/root.crt" ]] || log "warning: app-1 never published tunnel-gw secrets; starting anyway"
      fi
      if [[ "$ROLE" != kit ]]; then
          if vm-stack; then touch "$STATE_DIR/share/ready"; log "stack: up"; else log "stack: FAILED (rerun: qemu/rig-qemu stack $NODE)"; fi
      else touch "$STATE_DIR/share/ready"; fi
  else log "guest never opened ssh"; fi ) &

wait "$QPID"
