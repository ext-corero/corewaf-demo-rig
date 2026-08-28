#!/usr/bin/env bash
# kit-prep.sh [name] — boot + stage the demo kit VM (not enrolled). v0.2: the kit is a
# node container on the rig network; staging runs inside it. Re-runnable.
set -euo pipefail
NAME="${1:-demo}"; SVC="kit-$NAME"
docker compose --profile kit up -d "$SVC"
docker compose --profile kit exec -T "$SVC" kit-stage
echo; echo "enrol: ./kit-enrol.sh $NAME <TOKEN>     console: task console NODE=$SVC     destroy: task demo:reset"
