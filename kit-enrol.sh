#!/usr/bin/env bash
# kit-enrol.sh <name> <TOKEN> — enrol a staged kit (token from `task demo:token`).
set -euo pipefail
NAME="${1:?usage: $0 <name> <token>}"; TOKEN="${2:?usage: $0 <name> <token>}"
docker compose --profile kit exec -T "kit-$NAME" kit-enrol "$TOKEN"
