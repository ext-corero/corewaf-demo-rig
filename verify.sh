#!/usr/bin/env bash
# v2/verify.sh — green/red checklist for the v2 multi-VM rig.
# VMs running -> every container healthy -> host-reachable endpoints ->
# DNS plane -> WG peers on the gateways -> registered WAF instances.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG_DIR="$HERE"
# shellcheck disable=SC1091
source "$HERE/inventory.env"
# shellcheck disable=SC1091
source "$HERE/lib/host.sh"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
SSH=(ssh -i "$(host_lab_dir)/id_lab" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
pass=0; fail=0
ok()   { printf '  \e[32m✓\e[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \e[31m✗\e[0m %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '  \e[33m~\e[0m %s\n' "$*"; }

echo "== VMs =="
for v in $RIG_APP_NAME $RIG_DNS_1_NAME $RIG_DNS_2_NAME $RIG_GW_1_NAME $RIG_GW_2_NAME $RIG_OBS_1_NAME; do
    st=$(virsh domstate "$v" 2>/dev/null || echo missing)
    [[ "$st" == running ]] && ok "$v running" || bad "$v $st"
done

echo "== containers =="
for r in "app:$RIG_APP_IP" "dns-1:$RIG_DNS_1_IP" "dns-2:$RIG_DNS_2_IP" "gw-1:$RIG_GW_1_IP" "gw-2:$RIG_GW_2_IP" "obs:$RIG_OBS_1_IP"; do
    name=${r%%:*}; ip=${r##*:}
    out=$("${SSH[@]}" "alpine@$ip" "doas docker ps -a --format '{{.Names}} {{.Status}}'" 2>/dev/null) || { bad "$name: ssh unreachable"; continue; }
    while read -r cname cstatus; do
        [[ -z "$cname" ]] && continue
        case "$cstatus" in
            Up*unhealthy*) bad "$name/$cname: $cstatus" ;;
            Up*)           ok  "$name/$cname" ;;
            "Exited (0)"*) ;;                             # one-shot init containers
            *)             bad "$name/$cname: $cstatus" ;;
        esac
    done <<<"$out"
done

echo "== endpoints (from host) =="
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
[[ $(code "http://$RIG_APP_FQDN:8080/health") == 200 ]] && ok "API  http://$RIG_APP_FQDN:8080/health" || bad "API  http://$RIG_APP_FQDN:8080/health (is $RIG_APP_FQDN in /etc/hosts?)"
[[ $(code "http://gui-1.$RIG_DOMAIN:8080/") == 200 ]] && ok "GUI  http://gui-1.$RIG_DOMAIN:8080" || bad "GUI  http://gui-1.$RIG_DOMAIN:8080"
[[ $(code "http://$RIG_OBS_1_IP:3000/api/health") == 200 ]] && ok "Grafana http://$RIG_OBS_1_IP:3000" || bad "Grafana http://$RIG_OBS_1_IP:3000"
for gw in "$RIG_GW_1_FQDN:$RIG_GW_1_IP" "$RIG_GW_2_FQDN:$RIG_GW_2_IP"; do
    f=${gw%%:*}; ip=${gw##*:}
    [[ $(code --cacert "$RIG_DIR/.v2/ca/root_ca.crt" --resolve "$f:443:$ip" "https://$f/health") == 200 ]] && ok "edge https://$f/health (valid cert)" || bad "edge https://$f/health — expired/missing cert? see docs/demo-kit.md troubleshooting"
done

echo "== dns plane =="
for ns in $RIG_RESOLVERS; do
    a=$(dig +short +time=2 +tries=1 "@$ns" "$RIG_APP_FQDN" 2>/dev/null)
    [[ "$a" == "$RIG_APP_IP" ]] && ok "$ns resolves $RIG_APP_FQDN" || bad "$ns does not resolve $RIG_APP_FQDN"
done
"${SSH[@]}" "alpine@$RIG_APP_IP" 'ping -c1 -W2 8.8.8.8 >/dev/null 2>&1' && ok "VM egress (masquerade present)" \
    || bad "VM egress — libvirt NAT not working (virsh net-dumpxml $RIG_NET_NAME: forward mode must be nat; RIG_NET_MODE=route needs a host masquerade)"

echo "== gateways: WG peers =="
for gw in "gw-1:$RIG_GW_1_IP" "gw-2:$RIG_GW_2_IP"; do
    n=$("${SSH[@]}" "alpine@${gw##*:}" "doas wg show 2>/dev/null | grep -c 'latest handshake'" 2>/dev/null | head -1); n=${n:-0}
    [[ "$n" -gt 0 ]] && ok "${gw%%:*}: $n peer(s) with a handshake" || warn "${gw%%:*}: no active peers"
done

echo "== registered WAF instances =="
curl -s --max-time 5 -H 'X-Scope-OrgID: corero-system-owner' "http://$RIG_APP_FQDN:8080/caddys/api/v1/namespaces/corero-core/caddy/instances" \
| python3 -c "$(cat <<'PY'
import sys,json,datetime
now=datetime.datetime.now(datetime.timezone.utc)
for e in json.load(sys.stdin).get("instances",[]):
    i=e["instance"]; ls=i["status"].get("lastSeen")
    age="never"
    if ls:
        t=datetime.datetime.fromisoformat(ls.replace("Z","+00:00")); age=f"{int((now-t).total_seconds())}s ago"
    print(f"  {i['metadata']['name'][:8]}  {i['status'].get('phase','?'):9} lastSeen {age}")
PY
)" 2>/dev/null || warn "could not list instances"

echo
printf '== summary: \e[32m%d pass\e[0m · \e[31m%d fail\e[0m ==\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
