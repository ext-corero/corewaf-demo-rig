#!/usr/bin/env bash
# CoreWAF demo rig — enrol a WAF kit, fully automatic (curl-pipe).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/kit.sh) [demo|a|b]
#
# Against a rig already running on this Docker host (bootstrap.sh), this boots one
# more VM — a kit node with a TPM — on the rig network, stages the public starter-kit
# in it, mints a provisioning token from the rig's API, enrols the kit over the
# gateway TLS edge + WireGuard, and prints the resulting WAF instance. Re-running
# on the same name re-enrols that kit (same hwId).
#
#   COREWAF_RIG_DIR   checkout to use (default ./corewaf-demo-rig, cloned if missing)
#   TENANT            owner tenant for the token (default: first demo tenant, else the
#                     system tunnel-gateway identity on a fresh rig)
#   KIT_REF           starter-kit branch/tag (default main)
set -euo pipefail
NAME="${1:-demo}"; case "$NAME" in demo|a|b) ;; *) echo "kit name must be demo, a or b" >&2; exit 2;; esac
SVC="kit-$NAME"
REPO_URL="${COREWAF_RIG_REPO:-https://github.com/ext-corero/corewaf-demo-rig.git}"; REF="${COREWAF_RIG_REF:-stable}"
DIR="${COREWAF_RIG_DIR:-corewaf-demo-rig}"
step() { printf '\n── %s ──\n' "$*"; }; ok() { printf '  \e[32m✓\e[0m %s\n' "$*"; }
fail() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

step "CoreWAF demo rig — kit '$NAME'"
command -v docker >/dev/null || fail "docker is required"
if [[ ! -f "$DIR/docker-compose.yml" ]]; then
    [[ -f docker-compose.yml && -f inventory.env ]] && DIR=. || { command -v git >/dev/null || fail "git is required"; git clone -q --branch "$REF" "$REPO_URL" "$DIR"; ok "cloned rig checkout → $DIR"; }
fi
cd "$DIR"
[[ "$(docker inspect -f '{{.State.Health.Status}}' rig-app-1 2>/dev/null)" == healthy ]] || fail "the rig is not running/healthy on this host (rig-app-1). Run bootstrap.sh first."
ok "rig is up"

step "Booting + staging the kit VM ($SVC)"
# self-heal: a force-removed kit container can leave a dangling endpoint holding its static IP
docker inspect "rig-$SVC" >/dev/null 2>&1 || docker network disconnect -f corewaf-rig "rig-$SVC" >/dev/null 2>&1 || true
docker compose --profile kit up -d "$SVC" >/dev/null 2>&1 || docker compose --profile kit up -d "$SVC"
docker compose --profile kit exec -T "$SVC" kit-stage 2>&1 | grep -E '^\s+(dns|edge|tpm)|staged' || true

step "Minting a provisioning token"
mint() { docker compose --profile tools run --rm -T cli rig mint "$SVC" "$1" 2>/dev/null | grep -E '^eyJ' | tail -1 || true; }
TOKEN="$(mint "${TENANT:-}")"
if [[ -z "$TOKEN" && -z "${TENANT:-}" ]]; then
    TOKEN="$(mint corero-system-owner-tunnel-gateway)"   # fresh rig: no demo tenants yet
fi
[[ -n "$TOKEN" ]] || fail "could not mint a token (TENANT=<owner> to choose one explicitly)"
ok "token minted (${#TOKEN} chars)"

step "Enrolling"
docker compose --profile kit exec -T "$SVC" kit-enrol "$TOKEN" 2>&1 | grep -E 'EVENT|enrolled' || fail "enrolment failed — docker compose --profile kit exec $SVC vm-ssh 'sudo docker logs corewaf-tunnel'"

step "Result"
docker compose --profile tools run --rm -T cli rig verify 2>/dev/null | sed -n '/WG peers/,/summary/p'
echo; echo "GUI → WAF instances → Pending: provision it (Role / Placement / WAF units / Lifecycle)."
echo "Console: task console NODE=$SVC   ·   ssh: task ssh NODE=$SVC   ·   remove: docker compose --profile kit rm -sf $SVC"
