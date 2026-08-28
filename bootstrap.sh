#!/usr/bin/env bash
# CoreWAF demo rig — curl-pipe bootstrap (v0.2: the rig is a set of containers, each
# running one VM under QEMU/KVM).
#
#   AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/bootstrap.sh)
#
# Needs on the host: Docker (Engine on Linux, or Docker Desktop on Windows with the
# WSL2 backend + nested virtualization), git, and an AWS credential for the CoreWAF
# registry (IAM user in group corewaf-ecr-pull) as AWS_PROFILE or AWS_ACCESS_KEY_ID/
# AWS_SECRET_ACCESS_KEY. No sudo, no packages, nothing built locally.
#   COREWAF_RIG_DIR / COREWAF_RIG_REF / NO_UP=1 as before.
set -euo pipefail
REPO_URL="${COREWAF_RIG_REPO:-https://github.com/ext-corero/corewaf-demo-rig.git}"
REF="${COREWAF_RIG_REF:-main}"; DIR="${COREWAF_RIG_DIR:-corewaf-demo-rig}"
REGISTRY_HOST="123517950721.dkr.ecr.us-east-1.amazonaws.com"; REGION="us-east-1"
step() { printf '\n── %s ──\n' "$*"; }; ok() { printf '  \e[32m✓\e[0m %s\n' "$*"; }; warn() { printf '  \e[33m!\e[0m %s\n' "$*"; }
fail() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

step "CoreWAF demo rig — bootstrap"
for c in git docker; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
docker compose version >/dev/null 2>&1 || fail "docker compose (v2) is required"
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') / $(docker compose version --short)"
step "KVM inside containers"
if docker run --rm --device /dev/kvm alpine:3.23 test -w /dev/kvm 2>/dev/null; then ok "/dev/kvm usable from a container"; else
    cat >&2 <<MSG
ERROR: /dev/kvm is not available to containers — the rig VMs need KVM.
  Linux   : enable VT-x/AMD-V in firmware; check 'ls -l /dev/kvm' and that your user can run docker.
  Windows : Docker Desktop with the WSL2 backend, and nested virtualization enabled:
            %UserProfile%\\.wslconfig ->  [wsl2]
                                         nestedVirtualization=true
            then 'wsl --shutdown' and restart Docker Desktop.
MSG
    exit 1
fi
step "Registry credential"
AWS_ARGS=(-e AWS_PROFILE -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -v "${HOME}/.aws:/root/.aws:ro")
if TOKEN="$(docker run --rm "${AWS_ARGS[@]}" public.ecr.aws/aws-cli/aws-cli ecr get-login-password --region "$REGION" 2>/dev/null)" && [[ -n "$TOKEN" ]]; then
    printf '%s' "$TOKEN" | docker login --username AWS --password-stdin "$REGISTRY_HOST" >/dev/null 2>&1 && ok "logged in to $REGISTRY_HOST (docker can pull the rig-node image)"
else
    cat >&2 <<MSG
ERROR: no usable AWS credential (or not in IAM group corewaf-ecr-pull).
  Ask the CoreWAF operators for an access key, then:
    aws configure --profile corewaf-ecr      # region ${REGION}   (or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)
    export AWS_PROFILE=corewaf-ecr
MSG
    exit 1
fi
step "Fetching ${REPO_URL} (${REF}) → ${DIR}"
if [[ -d "$DIR/.git" ]]; then git -C "$DIR" fetch -q origin "$REF" && git -C "$DIR" checkout -q "$REF" && git -C "$DIR" pull -q --ff-only origin "$REF"; ok "refreshed";
elif [[ -e "$DIR" ]]; then fail "$DIR exists but is not a git checkout";
else git clone -q --branch "$REF" "$REPO_URL" "$DIR"; ok "cloned"; fi
cd "$DIR"
[[ "${NO_UP:-0}" == 1 ]] && { echo; echo "Stopped after clone (NO_UP=1). Next: cd $DIR && docker compose up -d"; exit 0; }
step "docker compose up -d   (rig-init pulls the VM base image once, then boots 6 VMs)"
docker compose up -d
echo; bash scripts/hosts-block.sh; echo
echo "Then: cd $DIR && docker compose --profile tools run --rm cli rig verify   (or 'task verify')"
