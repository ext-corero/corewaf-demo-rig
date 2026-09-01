#!/usr/bin/env bash
# rig-launcher — the demo rig from a single `docker run` (Docker socket + AWS credential).
#
#   up        clone/refresh the rig into volume corewaf-demo-rig_repo, pick ports, compose up
#   status    node containers + health          verify   health checklist (inside the rig network)
#   ps | stat                                    containers / uptime+load+mem inside every guest
#   logs NODE CTR [args]                         logs of a container inside a guest (--tail 50)
#   exec NODE CTR CMD...                         run a command in a container inside a guest
#   kit NAME  boot + stage + mint + enrol a kit, fully automatic (demo|a|b)
#   stage NAME  boot + stage + mint but do NOT enrol — manual in-VM demo (prints TOKEN=...)
#   portal    Backstage developer portal (plain container) on :27007
#   refresh-kits  recreate the kit node containers (fixes kits gone stale; enrolments persist)
#   stop | down | reset                          console NODE (VM serial log)   url   browser URLs
#   shell     bash in the launcher with the checkout mounted (debug)
set -euo pipefail
REPO_URL="${COREWAF_RIG_REPO:-https://github.com/ext-corero/corewaf-demo-rig.git}"
# Channel = the launcher image tag you ran: :stable -> stable branch, :vX.Y.Z -> that
# tag, anything else -> main. COREWAF_RIG_REF always overrides. LAUNCHER_IMAGE is set
# on the inner re-exec; the outer run self-inspects below before it matters.
channel_ref() {
    local tag="${LAUNCHER_IMAGE:-}"; tag="${tag##*:}"
    case "$tag" in stable) echo stable ;; v[0-9]*) echo "$tag" ;; *) echo main ;; esac
}
REF="${COREWAF_RIG_REF:-$(channel_ref)}"
PROJECT=corewaf-demo-rig; VOL="${PROJECT}_repo"; DIR=/rig/repo
REGISTRY_HOST="123517950721.dkr.ecr.us-east-1.amazonaws.com"; REGION="us-east-1"
step() { printf '\n── %s ──\n' "$*"; }; ok() { printf '  \e[32m✓\e[0m %s\n' "$*"; }; warn() { printf '  \e[33m!\e[0m %s\n' "$*"; }
fail() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }
cmd="${1:-help}"; shift || true
[[ -S /var/run/docker.sock ]] || fail "mount the Docker socket: -v /var/run/docker.sock:/var/run/docker.sock"
docker info >/dev/null 2>&1 || fail "cannot talk to the Docker daemon through the socket"

# ---- outer/inner: the user runs us with just the socket (+ ~/.aws). We resolve the
# credential, then re-exec ourselves with the repo volume attached (compose needs the
# files locally). RIG_LAUNCHER_INNER marks the inner run.
aws_from_profile() {
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_PROFILE:-}" && -f /root/.aws/credentials ]]; then
        AWS_ACCESS_KEY_ID="$(awk -v p="[$AWS_PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/aws_access_key_id/{sub(/.*= */,"");print;exit}' /root/.aws/credentials)"
        AWS_SECRET_ACCESS_KEY="$(awk -v p="[$AWS_PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/aws_secret_access_key/{sub(/.*= */,"");print;exit}' /root/.aws/credentials)"
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi
}
if [[ "${RIG_LAUNCHER_INNER:-0}" != 1 ]]; then
    aws_from_profile
    docker volume inspect "$VOL" >/dev/null 2>&1 || docker volume create "$VOL" >/dev/null
    IMG="${LAUNCHER_IMAGE:-$(docker inspect -f '{{.Config.Image}}' "$(hostname)" 2>/dev/null || true)}"
    [[ -n "$IMG" ]] || fail "cannot determine my own image; pass -e LAUNCHER_IMAGE=<image>"
    TTY=""; [[ -t 0 && -t 1 ]] && TTY="-it"
    exec docker run --rm $TTY -v /var/run/docker.sock:/var/run/docker.sock -v "$VOL:$DIR" \
        -e RIG_LAUNCHER_INNER=1 -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
        -e RIG_HTTP_PORT -e RIG_GRAFANA_PORT -e RIG_STEPCA_PORT -e RIG_BACKSTAGE_PORT -e COREWAF_RIG_REF -e TENANT -e LAUNCHER_IMAGE="$IMG" \
        "$IMG" "$cmd" "$@"
fi
ensure_repo() {
    REF="${COREWAF_RIG_REF:-$(channel_ref)}"   # inner run: LAUNCHER_IMAGE env is now set
    if [[ -d "$DIR/.git" ]]; then
        # full refspec: a bare `fetch origin <branch>` does not create the local ref,
        # so switching channels (main <-> stable) in an existing volume would fail.
        git -C "$DIR" fetch -q origin '+refs/heads/*:refs/remotes/origin/*' --tags 2>/dev/null || true
        # track the remote exactly: channel branches (stable) may be force-moved
        # by a release, so ff-pulls are not enough; tags check out detached.
        if git -C "$DIR" rev-parse -q --verify "origin/$REF" >/dev/null 2>&1; then
            git -C "$DIR" checkout -q -B "$REF" "origin/$REF"
        else
            git -C "$DIR" checkout -q "$REF"
        fi
        ok "rig checkout refreshed ($REF)"
    else git clone -q --branch "$REF" "$REPO_URL" "$DIR"; ok "rig cloned into volume $VOL ($REF)"; fi
    cd "$DIR"
}
# ---- AWS credential → env for rig-init (no host path can be mounted into rig-init from here) ----
aws_env() {
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || fail "no AWS credential: -e AWS_PROFILE=<profile> -v ~/.aws:/root/.aws:ro, or -e AWS_ACCESS_KEY_ID/-e AWS_SECRET_ACCESS_KEY"
    export AWS_DIR="${PROJECT}_aws"      # rig-init's ~/.aws mount becomes an (empty) volume; creds go via env
    export AWS_PROFILE=""
}
registry_login() {
    local tok; tok="$(echo "$REGISTRY_HOST" | docker-credential-ecr-login get 2>/dev/null | jq -r .Secret)"
    [[ -n "$tok" && "$tok" != null ]] || fail "AWS credential cannot get a registry token (must be in IAM group corewaf-ecr-pull)"
    printf '%s' "$tok" | docker login --username AWS --password-stdin "$REGISTRY_HOST" >/dev/null 2>&1; ok "registry login ($REGISTRY_HOST)"
}
compose() { docker compose -f docker-compose.yml -f compose/launcher.yml "$@"; }
pick_ports() {
    touch .env; local ports ours
    ports="$(docker run --rm --net host alpine:3.23 sh -c 'netstat -ltn 2>/dev/null | awk "{print \$4}" | sed "s/.*://" | sort -u' 2>/dev/null || true)"
    ours="$(docker ps --filter name=rig- --format '{{.Ports}}' | grep -oE ':[0-9]+->' | tr -d ':>-' | sort -u || true)"
    ports="$(comm -23 <(echo "$ports" | sort -u) <(echo "$ours" | sort -u))"
    for spec in RIG_HTTP_PORT:28080 RIG_GRAFANA_PORT:23000 RIG_STEPCA_PORT:29000 RIG_BACKSTAGE_PORT:27007; do
        local var="${spec%%:*}" def="${spec##*:}" cur want p
        # preference: explicit env override > the default port > whatever a previous run recorded
        cur="$(sed -n "s/^$var=//p" .env | tail -1)"; want="${!var:-$def}"; p="$want"
        [[ -z "${!var:-}" && -n "$cur" ]] && ! echo "$ports" | grep -qx "$def" && p="$def"
        [[ -z "${!var:-}" && -n "$cur" ]] && echo "$ports" | grep -qx "$def" && p="$cur"
        while echo "$ports" | grep -qx "$p"; do p=$((p+1)); done
        sed -i "/^$var=/d" .env; echo "$var=$p" >> .env; [[ "$p" == "$def" ]] && ok "$var=$p" || warn "$var=$p ($def in use)"
    done
}
kvm_check() { docker run --rm --device /dev/kvm alpine:3.23 test -w /dev/kvm >/dev/null 2>&1 && ok "/dev/kvm usable from containers" || fail "KVM not available to containers (Windows: .wslconfig [wsl2] nestedVirtualization=true, then wsl --shutdown)"; }
wait_healthy() {   # all infra node containers healthy (first boot can take ~10 min)
    local want=6 n=0 t=0; printf '  waiting for the VMs to come up (stacks start inside the guests)'
    while (( t < 1200 )); do n="$(docker ps --filter name=rig- --filter health=healthy -q | wc -l)"; (( n >= want )) && { echo " ok ($n/$want)"; return 0; }; printf .; sleep 15; t=$((t+15)); done
    echo; warn "only $n/$want nodes healthy after 20 min — check: rig-launcher status / logs <node>"
}
wait_api() {       # the rig API must answer before minting tokens
    local t=0; while (( t < 300 )); do compose --profile tools run --rm -T cli curl -sf -m5 "http://$RIG_APP_FQDN_DEFAULT:8080/health" >/dev/null 2>&1 && return 0; sleep 10; t=$((t+10)); done; return 1
}
RIG_APP_FQDN_DEFAULT=app-1.rig.internal
urls() { local h g; h="$(sed -n 's/^RIG_HTTP_PORT=//p' .env)"; g="$(sed -n 's/^RIG_GRAFANA_PORT=//p' .env)"; echo "GUI:     http://gui-1.localhost:${h:-28080}"; echo "Grafana: http://grafana.localhost:${g:-23000}"; }

case "$cmd" in
  up)     step "rig-launcher up"; ensure_repo; kvm_check; aws_env; registry_login; pick_ports
          step "docker compose up -d"; set -a; . .env; set +a; compose up -d; wait_healthy; echo; urls ;;
  status) ensure_repo; compose --profile kit ps ;;
  verify) ensure_repo; compose --profile tools run --rm -T cli rig verify ;;
  ps|stat|logs|exec) ensure_repo; compose --profile tools run --rm -T cli rig "$cmd" "$@" ;;
  kit)    ensure_repo; aws_env; registry_login; set -a; . .env; set +a
          NAME="${1:-demo}"; SVC="kit-$NAME"; step "kit $NAME"
          docker inspect "rig-$SVC" >/dev/null 2>&1 || docker network disconnect -f corewaf-rig "rig-$SVC" >/dev/null 2>&1 || true
          [[ "$(docker inspect -f '{{.State.Health.Status}}' rig-app-1 2>/dev/null)" == healthy ]] || fail "the rig is not up/healthy (run: rig-launcher up)"
          compose --profile kit up -d "$SVC"; compose --profile kit exec -T "$SVC" kit-stage | grep -E '^\s+(dns|edge|tpm)|staged' || true
          wait_api || fail "rig API not answering"
          TOKEN="$(compose --profile tools run --rm -T cli rig mint "$SVC" "${TENANT:-}" 2>/dev/null | grep -E '^eyJ' | tail -1 || true)"
          [[ -n "$TOKEN" || -n "${TENANT:-}" ]] || TOKEN="$(compose --profile tools run --rm -T cli rig mint "$SVC" corero-system-owner-tunnel-gateway 2>/dev/null | grep -E '^eyJ' | tail -1 || true)"
          [[ -n "$TOKEN" ]] || fail "could not mint a token"; ok "token minted"
          compose --profile kit exec -T "$SVC" kit-enrol "$TOKEN" || fail "enrolment failed — rig-launcher logs $SVC, or: docker exec rig-$SVC vm-ssh 'sudo docker logs corewaf-tunnel'"
          compose --profile tools run --rm -T cli rig verify 2>/dev/null | sed -n '/WG peers/,/summary/p' ;;
  stage)  ensure_repo; aws_env; registry_login; set -a; . .env; set +a
          NAME="${1:-demo}"; SVC="kit-$NAME"; step "stage $NAME (manual demo — staged + token, NOT enrolled)"
          docker inspect "rig-$SVC" >/dev/null 2>&1 || docker network disconnect -f corewaf-rig "rig-$SVC" >/dev/null 2>&1 || true
          [[ "$(docker inspect -f '{{.State.Health.Status}}' rig-app-1 2>/dev/null)" == healthy ]] || fail "the rig is not up/healthy (run: rig-launcher up)"
          compose --profile kit up -d "$SVC"; compose --profile kit exec -T "$SVC" kit-stage | grep -E '^\s+(dns|edge|tpm|img)|staged' || true
          wait_api || fail "rig API not answering"
          TOKEN="$(compose --profile tools run --rm -T cli rig mint "$SVC" "${TENANT:-}" 2>/dev/null | grep -E '^eyJ' | tail -1 || true)"
          [[ -n "$TOKEN" || -n "${TENANT:-}" ]] || TOKEN="$(compose --profile tools run --rm -T cli rig mint "$SVC" corero-system-owner-tunnel-gateway 2>/dev/null | grep -E '^eyJ' | tail -1 || true)"
          [[ -n "$TOKEN" ]] || fail "could not mint a token"
          echo "TOKEN=$TOKEN"
          echo "Kit $SVC is staged and NOT enrolled. Enrol it from INSIDE the VM (the customer experience):"
          echo "  terminal:  docker exec -it rig-$SVC vm-ssh          (or: docker exec -it rig-$SVC console — login alpine/alpine)"
          echo "  in the VM: NO_UP=1 TOKEN=<token> bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-starter-kit/main/bootstrap.sh)"
          echo "             corewaf-demo-up" ;;
  portal) ensure_repo; aws_env; registry_login; set -a; . .env; set +a
          step "Backstage portal (plain container, port ${RIG_BACKSTAGE_PORT:-27007})"
          compose --profile portal up -d backstage
          echo "Backstage: http://localhost:${RIG_BACKSTAGE_PORT:-27007}" ;;
  refresh-kits) ensure_repo; aws_env; registry_login; set -a; . .env; set +a
          step "refresh kits — recreate kit node containers (fresh network endpoints; VM disks, identities and enrolments persist)"
          KITS="$(docker ps -a --filter name=rig-kit- --format '{{.Names}}' | sed 's/^rig-//' | tr '\n' ' ')"
          [[ -n "${KITS// /}" ]] || { warn "no kit containers to refresh"; exit 0; }
          # shellcheck disable=SC2086
          compose --profile kit up -d --force-recreate $KITS
          for k in $KITS; do
              for _ in $(seq 1 60); do [[ "$(docker inspect -f '{{.State.Health.Status}}' "rig-$k" 2>/dev/null)" == healthy ]] && break; sleep 5; done
              ok "rig-$k $(docker inspect -f '{{.State.Health.Status}}' "rig-$k" 2>/dev/null)"
          done
          echo "kits rebooted — enrolled tunnels reconnect on their own within ~1 min (watch the GUI heartbeats)" ;;
  stop)   ensure_repo; compose --profile kit stop ;;
  down)   ensure_repo; compose --profile kit down ;;
  reset)  ensure_repo; compose --profile kit --profile tools down -v ;;
  console) ensure_repo; compose --profile kit logs -f --tail=100 "${1:-app-1}" ;;
  url)    ensure_repo; urls ;;
  shell)  ensure_repo; exec bash ;;
  *) sed -n '2,14p' "$0" ;;
esac
