#!/usr/bin/env bash
# bundle.sh — offline image bundle for air-gapped hosts.
#
#   bundle.sh save    on a host WITH registry access: pull every image in images.env
#                     (rig + kit + public) and docker-save them to .v2/bundle/
#   bundle.sh load    push the rig tar into every running infra VM and docker-load it
#                     (kit VMs get theirs from kit-prep.sh when RIG_BUNDLE=1)
#
# Then:  RIG_BUNDLE=1 ./up.sh   (compose runs with --pull never; no registry auth needed)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RIG_DIR="$HERE"
# shellcheck disable=SC1091
source "$HERE/inventory.env"; source "$HERE/lib/registry.sh"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
B="$HERE/.v2/bundle"; mkdir -p "$B"
SSH=(ssh -i "${LAB_DIR:-$HOME/vm-lab}/id_lab" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
log() { printf '\e[36m==>\e[0m %s\n' "$*"; }

cmd_save() {
    local reg; reg="$(reg_registry)"
    aws ecr get-login-password --region "$(reg_region)" | docker login --username AWS --password-stdin "$(reg_host)" >/dev/null
    local rig=() kit=()
    for i in $(reg_rig_images); do rig+=("$reg/$i"); done
    for i in $(reg_public_images); do rig+=("$i"); done
    for pair in $(reg_kit_pairs); do local src="${pair%%=>*}" dst="${pair##*=>}"; docker pull -q "$reg/$src"; docker tag "$reg/$src" "$dst"; kit+=("$dst"); done
    for i in $(reg_kit_public); do kit+=("$i"); done
    for i in "${rig[@]}"; do log "pull $i"; docker pull -q "$i"; done
    for i in "${kit[@]}"; do docker pull -q "$i" 2>/dev/null || true; done
    log "saving rig images -> $B/rig-images.tar"; docker save -o "$B/rig-images.tar" "${rig[@]}"
    log "saving kit images -> $B/kit-images.tar"; docker save -o "$B/kit-images.tar" "${kit[@]}"
    cp "$HERE/images.env" "$B/images.env"; ls -lh "$B"
}
cmd_load() {
    [[ -s "$B/rig-images.tar" ]] || { echo "no bundle at $B — run bundle.sh save on a host with registry access" >&2; exit 1; }
    for ip in $RIG_APP_IP $RIG_DNS_1_IP $RIG_DNS_2_IP $RIG_GW_1_IP $RIG_GW_2_IP $RIG_OBS_1_IP; do
        log "loading into $ip"
        scp -q -i "${LAB_DIR:-$HOME/vm-lab}/id_lab" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$B/rig-images.tar" "alpine@$ip:/tmp/rig-images.tar"
        "${SSH[@]}" "alpine@$ip" 'doas docker load -i /tmp/rig-images.tar >/dev/null && rm -f /tmp/rig-images.tar'
    done
}
case "${1:-}" in save) cmd_save ;; load) cmd_load ;; *) sed -n '2,10p' "$0"; exit 2 ;; esac
