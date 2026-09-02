#!/usr/bin/env bash
# check-pins.sh — until the legacy compose path retires, guest-image pins live
# twice: images.env (legacy) and services/*/service.json (orchestrator, the
# release knob). This asserts the pairs match so the two launch paths can never
# silently run different builds. Exits non-zero on drift.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source images.env; set +a
fail=0
chk() { # chk <label> <legacy-value> <manifest-json> <jq-path>
    local want got; want="$2"; got="$(jq -r "$4" "$3")"
    if [[ "$want" != "$got" ]]; then
        echo "DRIFT $1: images.env=$want vs $3=$got"; fail=1
    fi
}
chk waf-api        "$WAF_API_TAG"         services/waf-api/service.json   '.service.sources.api.version'
chk gui            "$WAF_GUI_TAG"         services/gui/service.json       '.service.sources.gui.version'
chk caddy-edge     "$CADDY_INTERNAL_TAG"  services/caddy-edge/service.json '.service.sources.caddy.version'
chk gw-caddy       "$CADDY_INTERNAL_TAG"  services/gw/service.json        '.service.sources.caddy.version'
chk obs-caddy      "$CADDY_INTERNAL_TAG"  services/obs/service.json       '.service.sources.caddy.version'
chk tunnel-gateway "$TUNNEL_GW_TAG"       services/gw/service.json        '.service.sources["tunnel-gateway"].version'
chk dns-bridge     "$DNS_BRIDGE_TAG"      services/dns/service.json       '.service.sources["dns-bridge"].version'
chk coredns        "$COREDNS_REDIS_TAG"   services/dns/service.json       '.service.sources.coredns.version'
chk vmsecd         "$SECRETS_MANAGER_TAG" services/vmsecd/service.json    '.service.sources.vmsecd.version'
chk etcd           "$ETCD_IMAGE"          services/etcd/service.json      '.service.variables.IMAGE_ETCD'
chk redis          "$REDIS_IMAGE"         services/redis/service.json     '.service.variables.IMAGE_REDIS'
chk dns-redis      "$REDIS_IMAGE"         services/dns/service.json       '.service.variables.IMAGE_REDIS'
chk step-ca        "$STEP_CA_IMAGE"       services/step-ca/service.json   '.service.variables.IMAGE_STEP_CA'
chk step-cli       "$STEP_CLI_IMAGE"      services/step-ca/service.json   '.service.variables.IMAGE_STEP_CLI'
chk loki           "$LOKI_IMAGE"          services/obs/service.json       '.service.variables.IMAGE_LOKI'
chk mimir          "$MIMIR_IMAGE"         services/obs/service.json       '.service.variables.IMAGE_MIMIR'
chk alertmanager   "$ALERTMANAGER_IMAGE"  services/obs/service.json      '.service.variables.IMAGE_ALERTMANAGER'
chk grafana        "$GRAFANA_IMAGE"       services/obs/service.json       '.service.variables.IMAGE_GRAFANA'
[[ $fail -eq 0 ]] && echo "pins in sync (images.env == services/*/service.json)"
exit $fail
