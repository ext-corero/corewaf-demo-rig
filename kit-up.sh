#!/usr/bin/env bash
# kit-up.sh [name] — prep + mint + enrol in one go.
set -euo pipefail
NAME="${1:-demo}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/kit-prep.sh" "$NAME"
TOKEN="$(docker compose --profile tools run --rm -T cli rig mint "kit-$NAME" "${TENANT:-}")"
[[ -n "$TOKEN" ]] || { echo "token mint failed (fresh rig? TENANT=corero-system-owner-tunnel-gateway)" >&2; exit 1; }
bash "$HERE/kit-enrol.sh" "$NAME" "$TOKEN"
