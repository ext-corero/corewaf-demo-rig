#!/usr/bin/env bash
# qemu/prep-host.sh — one-time host prep for the pure-QEMU rig mode (Model 3).
# Root work happens once here; rig-qemu itself then runs unprivileged.
#   packages: qemu-kvm qemu-img swtpm xorriso socat jq curl git openssl bind-tools acl libvirt
#   libvirt : ensure libvirtd active, user in libvirt+kvm groups
#   network : define+start the corewaf-rig-qemu NAT bridge (virbr-cwrig)
#   qemu    : allow the bridge in /etc/qemu/bridge.conf (qemu-bridge-helper)
#   tools   : oras + docker-credential-ecr-login pinned into /usr/local/bin
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say(){ printf '\033[36m==>\033[0m %s\n' "$*"; }; ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
. /etc/os-release; PM=""; case "${ID:-} ${ID_LIKE:-}" in *arch*) PM=pacman;; *debian*|*ubuntu*) PM=apt;; *fedora*|*rhel*) PM=dnf;; esac
say "host: ${PRETTY_NAME:-?} (pm: $PM)"
need=(qemu-system-x86_64 qemu-img swtpm xorriso socat jq curl git openssl dig setfacl virsh ssh)
miss=(); for c in "${need[@]}"; do command -v "$c" >/dev/null || miss+=("$c"); done
if ((${#miss[@]})); then
  say "installing: ${miss[*]}"
  case "$PM" in
    apt) sudo apt-get update -qq; sudo apt-get install -y -qq qemu-system-x86 qemu-utils swtpm xorriso socat jq curl git openssl bind9-dnsutils acl libvirt-daemon-system libvirt-clients openssh-client ;;
    dnf) sudo dnf install -y qemu-kvm qemu-img swtpm xorriso socat jq curl git openssl bind-utils acl libvirt openssh-clients ;;
    pacman) sudo pacman -S --noconfirm --needed qemu-desktop libvirt swtpm xorriso socat jq curl git openssl bind acl openssh dnsmasq ;;
    *) echo "install manually: ${miss[*]}" >&2; exit 1 ;;
  esac
fi
command -v oras >/dev/null || { say "installing oras"; t=$(mktemp -d); curl -fsSL -o "$t/o.tgz" https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz; tar -xzf "$t/o.tgz" -C "$t" oras; sudo install -m0755 "$t/oras" /usr/local/bin/oras; rm -rf "$t"; }
command -v docker-credential-ecr-login >/dev/null || { say "installing docker-credential-ecr-login"; sudo curl -fsSL -o /usr/local/bin/docker-credential-ecr-login https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/0.9.1/linux-amd64/docker-credential-ecr-login; sudo chmod +x /usr/local/bin/docker-credential-ecr-login; }
say "libvirt"
sudo systemctl enable --now libvirtd >/dev/null 2>&1 || sudo systemctl enable --now libvirtd.service
for g in libvirt kvm; do id -nG "$USER" | grep -qw "$g" || sudo usermod -aG "$g" "$USER" && true; done
say "network corewaf-rig-qemu (virbr-cwrig, NAT)"
if ! sudo virsh --connect qemu:///system net-info corewaf-rig-qemu >/dev/null 2>&1; then
  sudo virsh --connect qemu:///system net-define "$HERE/corewaf-rig.net.xml"
fi
sudo virsh --connect qemu:///system net-start corewaf-rig-qemu >/dev/null 2>&1 || true
sudo virsh --connect qemu:///system net-autostart corewaf-rig-qemu >/dev/null
ok "bridge $(ip -br addr show virbr-cwrig 2>/dev/null | awk '{print $3}')"
say "per-node taps (user-owned; no setuid helper needed)"
for n in app-1 dns-1 dns-2 gw-1 gw-2 obs-1 kit-demo kit-a kit-b; do
  t="tap-cw-$n"
  ip link show "$t" >/dev/null 2>&1 || sudo ip tuntap add dev "$t" mode tap user "$USER"
  sudo ip link set "$t" master virbr-cwrig up
done
ok "taps tap-cw-* on virbr-cwrig (recreate after a reboot by re-running prep)"
say "qemu-bridge-helper ACL"
sudo mkdir -p /etc/qemu; grep -qx "allow virbr-cwrig" /etc/qemu/bridge.conf 2>/dev/null || echo "allow virbr-cwrig" | sudo tee -a /etc/qemu/bridge.conf >/dev/null
H=""; for c in /usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper; do [[ -x $c ]] && H=$c; done
[[ -n "$H" ]] && sudo chmod u+s "$H" && ok "setuid $H"
say "optional /etc/hosts block (browser access to *.rig.internal):"
echo "  run: scripts/hosts-block.sh   # and paste the block with sudo"
ok "prep done — next: qemu/rig-qemu up"
