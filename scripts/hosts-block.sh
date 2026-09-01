#!/usr/bin/env bash
# hosts-block.sh — print the /etc/hosts (or Windows hosts) lines for the rig names.
# Linux: the docker bridge is local, so the real VM IPs work. Windows/Docker Desktop:
# container IPs are not reachable; use 127.0.0.1 + the published ports.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$HERE/inventory.env"; [[ -f "$HERE/.env" ]] && . "$HERE/.env"
echo "# Browser (any OS, no hosts file needed): GUI http://gui-1.localhost:${RIG_HTTP_PORT:-28080}   Grafana http://grafana.localhost:${RIG_GRAFANA_PORT:-23000}"
echo "# Optional hosts entries for the rig.internal names / command-line tools:"
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [[ "${OS:-}" == Windows_NT ]]; then
  echo "# Windows hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts) — via published ports:"
  echo "127.0.0.1  gui-1.$RIG_DOMAIN $RIG_APP_FQDN $RIG_OBS_1_FQDN grafana.$RIG_DOMAIN"
  echo "# GUI http://gui-1.$RIG_DOMAIN:${RIG_HTTP_PORT:-8080}  Grafana http://grafana.$RIG_DOMAIN:${RIG_GRAFANA_PORT:-3000}"
else
  echo "# /etc/hosts (Linux) — add once:"
  echo "$RIG_APP_IP    gui-1.$RIG_DOMAIN $RIG_APP_FQDN stepca.$RIG_DOMAIN"
  echo "$RIG_OBS_1_IP  $RIG_OBS_1_FQDN grafana.$RIG_DOMAIN"
  echo "$RIG_GW_1_IP   $RIG_GW_1_FQDN"; echo "$RIG_GW_2_IP   $RIG_GW_2_FQDN"
  echo "# GUI http://gui-1.$RIG_DOMAIN:8080  (or http://localhost:${RIG_HTTP_PORT:-28080} with a Host header)"
fi
