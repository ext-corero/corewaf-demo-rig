#!/usr/bin/env bash
# prep-host.sh — one-time host preparation for the CoreWAF demo rig.
#
# Everything that needs root happens here, once, behind a single sudo prompt;
# up.sh never needs privileges afterwards (libvirt NAT owns the network rules).
#
#   packages   qemu/kvm, libvirt, virt-install, swtpm, xorriso, acl, ovmf, dns/ssl
#              tools, curl, git, jq, python3, aws-cli, oras, task
#   libvirt    enable libvirtd (system URI), add $USER to libvirt+kvm, ACLs so
#              the qemu user can traverse this checkout + the lab dir
#   network    define the rig network (NAT) via vmlab.sh net-up
#   hosts      managed "# BEGIN/END corewaf-rig" block in /etc/hosts (from
#              inventory.env) so the browser/CLI resolve *.rig.internal
#   lab dir    .v2/lab (reuses ~/vm-lab if present, by symlink)
#   WSL2       sanity checks (nested virt, systemd) + the Windows-side note
#
# Re-runnable. CHECK_ONLY=1 reports without changing anything.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RIG_DIR="$HERE"
# shellcheck disable=SC1091
source "$HERE/inventory.env"; source "$HERE/lib/host.sh"
CHECK_ONLY="${CHECK_ONLY:-0}"
say()  { printf '\e[36m==>\e[0m %s\n' "$*"; }
ok()   { printf '  \e[32m✓\e[0m %s\n' "$*"; }
warn() { printf '  \e[33m!\e[0m %s\n' "$*"; }
die()  { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 1; }
SUDO=(sudo); [[ -n "${SUDO_ASKPASS:-}" ]] && SUDO=(sudo -A)
run() { if [[ "$CHECK_ONLY" == 1 ]]; then echo "    would: $*"; else "$@"; fi; }
sudo_run() { if [[ "$CHECK_ONLY" == 1 ]]; then echo "    would (root): $*"; else "${SUDO[@]}" "$@"; fi; }

# ---- distro / packages -------------------------------------------------------
. /etc/os-release
PM=""; case "${ID:-} ${ID_LIKE:-}" in
  *arch*)              PM=pacman ;;
  *debian*|*ubuntu*)   PM=apt ;;
  *fedora*|*rhel*|*centos*) PM=dnf ;;
esac
say "host: ${PRETTY_NAME:-unknown} (pm: ${PM:-unknown})$(host_is_wsl && echo ' — WSL2')"

need_cmds=(virsh virt-install qemu-img qemu-system-x86_64 swtpm xorriso setfacl dig curl git jq python3 aws oras task ssh)
missing=(); for c in "${need_cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if ((${#missing[@]})); then
    say "installing missing tools: ${missing[*]}"
    case "$PM" in
      apt) sudo_run apt-get update -qq
           sudo_run apt-get install -y -qq qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virtiofsd swtpm xorriso acl ovmf bind9-dnsutils curl git jq python3 openssh-client ;;
      dnf) sudo_run dnf install -y qemu-kvm qemu-img libvirt virt-install virtiofsd swtpm xorriso acl edk2-ovmf bind-utils curl git jq python3 openssh-clients ;;
      pacman) sudo_run pacman -S --noconfirm --needed qemu-desktop libvirt virt-install virtiofsd swtpm xorriso acl edk2-ovmf bind curl git jq python openssh dnsmasq ;;
      *) warn "unknown package manager — install: ${missing[*]}" ;;
    esac
    # tools without stable distro packages: pinned binaries under /usr/local/bin
    if ! command -v oras >/dev/null 2>&1; then
        say "installing oras 1.3.0"
        run bash -c 'set -e; t=$(mktemp -d); curl -fsSL -o "$t/oras.tgz" https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz; tar -xzf "$t/oras.tgz" -C "$t" oras; sudo install -m 0755 "$t/oras" /usr/local/bin/oras; rm -rf "$t"'
    fi
    if ! command -v task >/dev/null 2>&1; then
        say "installing task"
        run bash -c 'curl -fsSL https://taskfile.dev/install.sh | sudo sh -s -- -d -b /usr/local/bin'
    fi
    if ! command -v aws >/dev/null 2>&1; then
        say "installing aws-cli v2"
        run bash -c 'set -e; t=$(mktemp -d); curl -fsSL -o "$t/awscli.zip" https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip; (cd "$t" && python3 -c "import zipfile;zipfile.ZipFile(\"awscli.zip\").extractall()" && chmod +x aws/install aws/dist/aws && sudo ./aws/install --update); rm -rf "$t"'
    fi
fi
for c in "${need_cmds[@]}"; do command -v "$c" >/dev/null 2>&1 && ok "$c" || warn "$c still missing"; done

# ---- KVM / WSL ----------------------------------------------------------------
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok "/dev/kvm usable"; else
    if host_is_wsl; then
        warn "/dev/kvm not usable. WSL2 needs nested virtualization: in %UserProfile%\\.wslconfig add [wsl2] nestedVirtualization=true, then 'wsl --shutdown' and reopen"
    else warn "/dev/kvm not usable — enable VT-x/AMD-V in firmware; VMs would run under slow TCG"; fi
fi
if host_is_wsl; then
    [[ "$(ps -p 1 -o comm=)" == systemd ]] && ok "WSL2 systemd enabled" || warn "WSL2: enable systemd (/etc/wsl.conf: [boot] systemd=true) so libvirtd can run; then 'wsl --shutdown'"
    warn "WSL2: the rig subnet $RIG_NET_CIDR is not reachable from Windows by default. From an elevated PowerShell:  route add ${RIG_NET_CIDR%/*} mask $RIG_NET_NETMASK \$(wsl hostname -I | cut -d' ' -f1)   (or use the WSL shell/browser)"
fi

# ---- libvirt --------------------------------------------------------------------
say "libvirt"
sudo_run systemctl enable --now libvirtd >/dev/null 2>&1 || sudo_run systemctl enable --now libvirtd.socket >/dev/null 2>&1 || warn "could not enable libvirtd"
for g in libvirt kvm; do
    if id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then ok "$USER in group $g"; else sudo_run usermod -aG "$g" "$USER"; warn "added $USER to $g — re-login (or 'newgrp $g') before 'task up'"; fi
done
QU="$(host_qemu_user)"; say "ACLs for qemu user '$QU'"
mkdir -p "$HERE/.v2" "$HERE/.cache"
LAB="$(host_lab_dir)"
if [[ ! -e "$LAB" && -d "$HOME/vm-lab" ]]; then run ln -sfn "$HOME/vm-lab" "$LAB"; ok "lab dir -> existing ~/vm-lab"; fi
[[ "$CHECK_ONLY" == 1 ]] || mkdir -p "$LAB/instances" "$LAB/seeds"
d="$HERE"; while [[ "$d" != / ]]; do sudo_run setfacl -m "u:$QU:x" "$d" 2>/dev/null || true; d="$(dirname "$d")"; done
d="$(readlink -f "$LAB")"; while [[ "$d" != / ]]; do sudo_run setfacl -m "u:$QU:x" "$d" 2>/dev/null || true; d="$(dirname "$d")"; done
for p in "$HERE/.cache" "$HERE/.v2" "$(readlink -f "$LAB")"; do sudo_run setfacl -R -m "u:$QU:rwx" "$p" 2>/dev/null || true; sudo_run setfacl -R -d -m "u:$QU:rwx" "$p" 2>/dev/null || true; done
ok "ACLs applied"
if command -v aa-status >/dev/null 2>&1 && [[ "$PM" == apt ]]; then
    warn "AppArmor host: if VMs fail to start with virtiofs 'permission denied', set security_driver = \"none\" in /etc/libvirt/qemu.conf (or add the checkout to the libvirt-qemu abstraction) and restart libvirtd"
fi

# ---- network ------------------------------------------------------------------
say "rig network ($RIG_NET_NAME, NAT)"
if [[ "$CHECK_ONLY" == 1 ]]; then echo "    would: vmlab.sh net-up"; else LIBVIRT_DEFAULT_URI=qemu:///system "$HERE/vmlab.sh" net-up; fi

# ---- /etc/hosts block ---------------------------------------------------------
say "host name resolution (/etc/hosts managed block)"
BLOCK="# BEGIN corewaf-rig (managed by demo-rig/prep-host.sh — do not edit)
$RIG_APP_IP    $RIG_APP_FQDN gui-1.$RIG_DOMAIN api-1.$RIG_DOMAIN stepca.$RIG_DOMAIN
$RIG_DNS_1_IP  $RIG_DNS_1_FQDN
$RIG_DNS_2_IP  $RIG_DNS_2_FQDN
$RIG_GW_1_IP   $RIG_GW_1_FQDN
$RIG_GW_2_IP   $RIG_GW_2_FQDN
$RIG_OBS_1_IP  $RIG_OBS_1_FQDN grafana.$RIG_DOMAIN loki.$RIG_DOMAIN mimir.$RIG_DOMAIN alertmanager.$RIG_DOMAIN
# END corewaf-rig"
if [[ "$CHECK_ONLY" == 1 ]]; then echo "    would: write managed block to /etc/hosts"; else
    tmp="$(mktemp)"; sed '/^# BEGIN corewaf-rig/,/^# END corewaf-rig/d' /etc/hosts > "$tmp"; printf '%s\n' "$BLOCK" >> "$tmp"
    "${SUDO[@]}" cp "$tmp" /etc/hosts; rm -f "$tmp"; ok "/etc/hosts updated"
fi
getent hosts "$RIG_APP_FQDN" >/dev/null && ok "$RIG_APP_FQDN resolves" || warn "$RIG_APP_FQDN does not resolve"

# ---- registry credential ------------------------------------------------------
say "registry credential"
if aws sts get-caller-identity >/dev/null 2>&1; then ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"; else
    warn "no AWS credentials in this shell — the rig pulls from the CoreWAF registry. Set AWS_PROFILE (aws configure --profile corewaf-ecr) with the key your operator issued (IAM group corewaf-ecr-pull)"; fi
say "done. Next: task up"
