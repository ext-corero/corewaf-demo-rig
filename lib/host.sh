#!/usr/bin/env bash
# lib/host.sh — host-side helpers shared by vmlab.sh, vm/vmlab.sh, prep-host.sh.
# Source it; expects $RIG_DIR.

# Where per-host VM state lives (disks, seeds, ssh key). Kept OUT of $HOME so a
# clone is self-contained; prep-host.sh symlinks an existing ~/vm-lab here.
host_lab_dir() { echo "${LAB_DIR:-${RIG_DIR:?}/.v2/lab}"; }

# virt-install: prefer the distro's own python + script (devbox/nix python on
# PATH lacks PyGObject), else whatever is on PATH.
host_virt_install() {
    if [[ -x /usr/bin/virt-install && -x /usr/bin/python3 ]]; then echo "/usr/bin/python3 /usr/bin/virt-install"
    elif command -v virt-install >/dev/null; then command -v virt-install
    else echo "error: virt-install not found (run prep-host.sh)" >&2; return 1; fi
}
# Newest alpinelinux os-variant libosinfo knows, falling back to generic detection.
host_osinfo_arg() {
    local v
    v="$(osinfo-query os 2>/dev/null | awk '/^ *alpinelinux/{print $1}' | sort -V | tail -1)"
    if [[ -n "$v" ]]; then echo "--osinfo $v"; else echo "--osinfo detect=on,require=off"; fi
}
# The uid libvirt runs qemu as (needs traversal ACLs into our dirs).
host_qemu_user() {
    local u; u="$(sed -n 's/^user *= *"\([^"]*\)".*/\1/p' /etc/libvirt/qemu.conf 2>/dev/null | head -1)"
    [[ -n "$u" ]] && { echo "$u"; return; }
    for c in libvirt-qemu qemu; do id "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done
    echo root
}
host_is_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }
