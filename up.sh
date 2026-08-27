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
# Egress masquerade needs host privileges; if $SUDO_ASKPASS is set we use it,
# otherwise we print the rule for you to add once.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
# shellcheck disable=SC1091
source "$HERE/inventory.env"
VMLAB="$HERE/vmlab.sh"

ensure_masquerade() {
    local rule=(-t nat POSTROUTING -s "$RIG_NET_CIDR" ! -d "$RIG_NET_CIDR" -j MASQUERADE)
    local SUDO=(sudo)
    [[ -n "${SUDO_ASKPASS:-}" ]] && SUDO=(sudo -A)
    if "${SUDO[@]}" iptables -C "${rule[@]}" 2>/dev/null; then
        echo "[net] egress masquerade present"
    elif "${SUDO[@]}" iptables -A "${rule[@]}" 2>/dev/null; then
        echo "[net] egress masquerade added"
    else
        echo "[net] WARNING: could not add egress masquerade (need privileges)." >&2
        echo "      Run once:  sudo iptables -A nat ... or:" >&2
        echo "      sudo iptables -t nat -A POSTROUTING -s $RIG_NET_CIDR ! -d $RIG_NET_CIDR -j MASQUERADE" >&2
    fi
}

echo "== network =="
"$VMLAB" net-up
ensure_masquerade

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
