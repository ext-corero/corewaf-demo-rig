#!/usr/bin/env bash
# v2/up.sh — bring up the whole demo rig multi-VM topology.
#
#   1. ensure the routed network + egress masquerade
#   2. create the 6 infra VMs (app, dns-1, dns-2, gw-1, gw-2, obs)
#   3. bring each role's docker stack up from the mapped source
#
# Self-assembly: stacks are started app -> dns -> gw as a sensible default,
# but every cross-VM-dependent container has restart:unless-stopped, so order
# isn't load-bearing — a stack that starts before its dependency is reachable
# just retries until the graph converges. Re-runnable.
#
# Egress: the rig network is libvirt NAT — libvirtd masquerades, no host rule needed.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
# shellcheck disable=SC1091
source "$HERE/inventory.env"
VMLAB="$HERE/vmlab.sh"

# Name resolution for the operator's browser/CLI: prep-host.sh writes a managed
# block into /etc/hosts (from inventory.env). Just warn if it's missing.
check_host_resolution() {
    if ! getent hosts "$RIG_APP_FQDN" >/dev/null 2>&1; then
        echo "[hosts] WARNING: $RIG_APP_FQDN does not resolve on this host — run prep-host.sh (adds the rig names to /etc/hosts)" >&2
    fi
}

echo "== base image =="
"$HERE/scripts/fetch-base.sh"

echo "== ca + secrets =="
"$HERE/ca-init.sh"

echo "== network =="
"$VMLAB" net-up
check_host_resolution

echo "== create VMs =="
"$VMLAB" create app
"$VMLAB" create dns 1
"$VMLAB" create dns 2
"$VMLAB" create gw 1
"$VMLAB" create gw 2
"$VMLAB" create obs

echo "== bring up stacks (app -> dns -> secrets -> gw; restart-until-ready settles the rest) =="
"$VMLAB" stack app
"$VMLAB" stack dns 1
"$VMLAB" stack dns 2
# secrets-manager (vmsecd) co-located on each dns VM as its own compose
# project (name: secrets-rig); self-registers into the fleet as
# system-secrets-manager via the app VM's provisioning API.
"$VMLAB" stack secrets 1
"$VMLAB" stack secrets 2
"$VMLAB" stack gw 1
"$VMLAB" stack gw 2
# observability plane (loki/mimir/alertmanager/grafana) on its own VM.
"$VMLAB" stack obs

echo
echo "demo rig up. VMs:"
"$VMLAB" list
echo
echo "GUI     : http://gui-1.rig.internal:8080   (resolve via the dns VMs or add to /etc/hosts)"
echo "API     : http://app-1.rig.internal:8080"
echo "Grafana : http://obs-1.rig.internal:3000   (anon viewer; Loki + Mimir datasources)"
