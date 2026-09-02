#!/usr/bin/env bash
# seed.sh — render the NoCloud seed for this node from the rig env and pack it.
# Same user-data as the libvirt era (identity file, resolv.conf, docker auth,
# ssh key, CA trust) with 9p mounts; plus static networking (network-config v1).
# Usage: seed.sh <out-dir>   (needs NODE_KEY, ROLE, NODE_IP, NODE_MAC, NODE_FQDN, MTU)
set -euo pipefail
source "${RIG_LIB:-/usr/local/bin/rig-lib.sh}"
OUT="${1:?out dir}"; mkdir -p "$OUT"
pubkey="$(<"$SSH_DIR/id_lab.pub")"
short="${NODE_FQDN%.$RIG_DOMAIN}"
resolvers=""; for ns in $RIG_RESOLVERS; do resolvers+="nameserver $ns\n"; done
# "node" = this node's hypervisor forwarder on the aux IP (see entrypoint.sh); an IP is used verbatim
if [[ "${RIG_BOOTSTRAP_RESOLVER:-}" == node ]]; then
    if [[ "${RIG_NET_MODE:-router}" == bridge ]]; then RIG_BOOTSTRAP_RESOLVER="${RIG_BOOTSTRAP_RESOLVER_BRIDGE:-1.1.1.1}"
    else RIG_BOOTSTRAP_RESOLVER="$AUX_IP"; fi
fi
[[ -n "${RIG_BOOTSTRAP_RESOLVER:-}" ]] && resolvers+="nameserver $RIG_BOOTSTRAP_RESOLVER\n"
dns_list="$(echo $RIG_RESOLVERS ${RIG_BOOTSTRAP_RESOLVER:-} | sed 's/ /, /g')"
# Two network modes:
#   router (default) — container mode: the node container (aux IP) is the guest's
#     router for EVERYTHING; the guest carries a /32 (Docker Desktop's fabric
#     blackholes long-registered identities; routing via the container's own
#     identity sidesteps it; on Linux it is a harmless extra NAT hop).
#   bridge — pure-QEMU host mode (qemu/rig-qemu): classic /24 on a libvirt NAT
#     bridge, default gw = the bridge address; VMs are directly addressable.
NET_MODE="${RIG_NET_MODE:-router}"
if [[ "$NET_MODE" == bridge ]]; then
    GW="$RIG_NET_HOST_GW"
else
    GW="$AUX_IP"
fi

bootstrap="NODE_NAME=$short\nFQDN=$NODE_FQDN\nZONE=$RIG_DOMAIN\nNODE_IP=$NODE_IP\n"
# the host port the hypervisor publishes the GUI/API on (browser-facing *.localhost URLs)
if [[ -n "${RIG_HTTP_PORT:-}" ]]; then bootstrap+="RIG_HTTP_PORT=$RIG_HTTP_PORT\nPUBLIC_API_HOST=app-1.localhost:$RIG_HTTP_PORT\n"
else bootstrap+="PUBLIC_API_HOST=app-1.$RIG_DOMAIN:8080\n"; fi
if [[ "$ROLE" == gw ]]; then
    cidr="$(node_var IPAM_CIDR)"; addr="$(node_var WG_ADDR)"
    [[ -n "$cidr" ]] && bootstrap+="IPAM_CIDR=$cidr\n"; [[ -n "$addr" ]] && bootstrap+="WG_ADDR=$addr\n"
fi
auth_json="$(cat "$AUTH_DIR/docker-config.json")"
# Prefer the durable form: credHelpers + the AWS key (guest mints tokens itself).
aws_creds=""; if [[ -s "$AUTH_DIR/aws-credentials" ]]; then
    auth_json="$(printf '{"credHelpers": {"%s": "ecr-login"}}' "$(reg_host)")"
    aws_creds="$(cat "$AUTH_DIR/aws-credentials")"
fi
P9="trans=virtio,version=9p2000.L,cache=none,msize=512000"

if [[ "$ROLE" == kit ]]; then
mounts="  - modprobe 9pnet_virtio || true
  - modprobe tpm_crb || true
  - mkdir -p /opt/kit-shim
  - mount -t 9p -o $P9,ro kitshim /opt/kit-shim || true
  - sh -c 'echo \"kitshim /opt/kit-shim 9p $P9,ro 0 0\" >> /etc/fstab'
  - chown alpine:alpine /home/alpine || true"
else
mounts="  - modprobe 9pnet_virtio || true
  - mkdir -p /opt/v2 /opt/shared-secrets /opt/rig-ca /opt/rig-state
  - mount -t 9p -o $P9,ro v2cfg /opt/v2 || true
  - mount -t 9p -o $P9 secrets /opt/shared-secrets || true
  - mount -t 9p -o $P9,ro rigca /opt/rig-ca || true
  - mount -t 9p -o $P9 nodestate /opt/rig-state || true
  - sh -c 'for t in \"v2cfg /opt/v2 ro\" \"secrets /opt/shared-secrets rw\" \"rigca /opt/rig-ca ro\" \"nodestate /opt/rig-state rw\"; do set -- \$t; echo \"\$1 \$2 9p $P9,\$3 0 0\" >> /etc/fstab; done'
  - mkdir -p /usr/local/share/ca-certificates
  - cp /opt/rig-ca/root_ca.crt /usr/local/share/ca-certificates/corewaf-rig-root.crt
  - update-ca-certificates || true
  - addgroup alpine docker || true
  - rc-update add docker default || true
  - rc-service docker start || true"
fi
if [[ "${RIG_MODE:-pull}" == source && "$ROLE" != kit ]]; then
mounts+="
  - mkdir -p $RIG_WORKSPACE_MOUNT && mount -t 9p -o $P9,ro workspace $RIG_WORKSPACE_MOUNT || true"
fi

{
cat <<UD
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
  - grep -q ttyS1 /etc/inittab || echo 'ttyS1::respawn:/sbin/getty -L 115200 ttyS1 vt100' >> /etc/inittab
  - kill -HUP 1
  - ip link set eth0 up || true
$( if [[ "$NET_MODE" == bridge ]]; then
cat <<B
  - ip addr replace $NODE_IP/24 dev eth0 || true
  - ip route replace default via $GW || true
B
else
cat <<B
  - ip addr replace $NODE_IP/32 dev eth0 || true
  - ip route replace $GW/32 dev eth0 || true
  - ip route replace default via $GW || true
B
fi )
write_files:
  - path: /etc/resolv.conf
    content: |
UD
printf '%b' "$resolvers" | sed 's/^/      /'
cat <<UD
      search $RIG_DOMAIN
  - path: /etc/network/interfaces
    content: |
      auto lo
      iface lo inet loopback
      auto eth0
      iface eth0 inet static
$( if [[ "$NET_MODE" == bridge ]]; then
cat <<B
        address $NODE_IP/24
        gateway $GW
        mtu \${MTU:-1500}
B
else
cat <<B
        address $NODE_IP/32
        mtu \${MTU:-1500}
        post-up ip route replace $GW/32 dev eth0
        post-up ip route replace default via $GW
B
fi )
  - path: /etc/corewaf-bootstrap
    permissions: '0644'
    content: |
UD
printf '%b' "$bootstrap" | sed 's/^/      /'
cat <<UD
  - path: /root/.docker/config.json
    permissions: '0600'
    content: |
      $auth_json
$( [[ -n "$aws_creds" ]] && { echo "  - path: /root/.aws/credentials"; echo "    permissions: '0600'"; echo "    content: |"; printf '%s\n' "$aws_creds" | sed 's/^/      /'; } )
runcmd:
$mounts
final_message: "rig VM $short ready (uptime: \$UPTIME s)"
UD
} > "$OUT/user-data"
iid="$short-$(sha256sum "$OUT/user-data" | cut -c1-12)"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$iid" "$short" > "$OUT/meta-data"
cat > "$OUT/network-config" <<NC
version: 1
config:
  - type: physical
    name: eth0
    mac_address: "$NODE_MAC"
    mtu: ${MTU:-1500}
    subnets:
$( if [[ "$NET_MODE" == bridge ]]; then
cat <<B
      - type: static
        address: $NODE_IP/24
        gateway: $GW
        dns_nameservers: [$dns_list]
        dns_search: [$RIG_DOMAIN]
B
else
cat <<B
      - type: static
        address: $NODE_IP/32
        routes:
          - network: $GW
            netmask: 255.255.255.255
            gateway: 0.0.0.0
          - network: 0.0.0.0
            netmask: 0.0.0.0
            gateway: $GW
        dns_nameservers: [$dns_list]
        dns_search: [$RIG_DOMAIN]
B
fi )
NC
xorriso -as mkisofs -quiet -V cidata -o "$OUT/seed.iso" -J -r -graft-points \
  "user-data=$OUT/user-data" "meta-data=$OUT/meta-data" "network-config=$OUT/network-config"
echo "$iid"
