#!/usr/bin/env bash
# v2/down.sh — tear down the demo rig topology (destroys the 6 infra VMs).
# The routed network + egress masquerade are left in place (cheap, reusable);
# pass --net to also destroy the network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
# shellcheck disable=SC1091
source "$HERE/inventory.env"
VMLAB="$HERE/vmlab.sh"
SHARED_SECRETS="$HERE/.v2/shared-secrets"

"$VMLAB" destroy obs   || true
"$VMLAB" destroy gw 2  || true
"$VMLAB" destroy gw 1  || true
"$VMLAB" destroy dns 2 || true
"$VMLAB" destroy dns 1 || true
"$VMLAB" destroy app   || true

# Per-CA shared secrets (step-ca provisioner.jwk, root fingerprint, bridges
# cert, the bootstrap sentinel) are tied to the step-ca instance that lived in
# the app VM — now destroyed. Clear them so the next bring-up's stepca-bootstrap
# re-registers the ACME + tunnel-gateway provisioners against the FRESH CA
# (otherwise the stale sentinel makes it skip and the edge can't ACME). The
# pre-created rig root (v2/ca/) is separate and stays.
rm -rf "$SHARED_SECRETS/tunnel-gw" 2>/dev/null || true
echo "cleared per-CA shared secrets ($SHARED_SECRETS/tunnel-gw)"

if [[ "${1:-}" == "--net" ]]; then
    "$VMLAB" net-down || true
    echo "network corewaf-rig destroyed"
fi
echo "rig v2 down."
