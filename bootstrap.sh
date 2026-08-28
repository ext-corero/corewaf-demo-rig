#!/usr/bin/env bash
# CoreWAF demo rig — curl-pipe bootstrap.
#
#   AWS_PROFILE=corewaf-ecr bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-demo-rig/main/bootstrap.sh)
#
# Thin by design: checks the host and your registry credential, clones (or
# refreshes) this repo, then hands off to `task prep-host` (one sudo prompt,
# once) and `task up`. Everything else — VM base image, every container image —
# is pulled from the CoreWAF registry; nothing is built on your machine.
#
# Required: an AWS credential for the CoreWAF registry (an IAM access key in
#   group corewaf-ecr-pull, issued by the CoreWAF operators) — as AWS_PROFILE,
#   or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in the environment.
# Optional:
#   COREWAF_RIG_DIR   where to clone (default ./corewaf-demo-rig)
#   COREWAF_RIG_REF   branch/tag (default main)
#   NO_PREP=1         skip `task prep-host` (host already prepared)
#   NO_UP=1           stop after the clone + checks
set -euo pipefail

REPO_URL="${COREWAF_RIG_REPO:-https://github.com/ext-corero/corewaf-demo-rig.git}"
REF="${COREWAF_RIG_REF:-main}"
DIR="${COREWAF_RIG_DIR:-corewaf-demo-rig}"
REGISTRY_HOST="123517950721.dkr.ecr.us-east-1.amazonaws.com"
REGION="us-east-1"

step() { printf '\n── %s ──\n' "$*"; }
ok()   { printf '  \e[32m✓\e[0m %s\n' "$*"; }
fail() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

step "CoreWAF demo rig — bootstrap"

# ── host prerequisites (the bare minimum to get going; prep-host installs the rest)
for c in git curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
[[ "$(uname -s)" == Linux ]] || fail "Linux (incl. WSL2) is required"
if [[ -e /dev/kvm ]]; then ok "/dev/kvm present"; else
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        printf '  \e[33m!\e[0m WSL2 without /dev/kvm — enable nested virtualization (%s) then `wsl --shutdown`\n' '%UserProfile%\.wslconfig: [wsl2] nestedVirtualization=true'
    else printf '  \e[33m!\e[0m /dev/kvm missing — enable VT-x/AMD-V; VMs will be very slow without it\n'; fi
fi
ok "host: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-linux}")"

# ── registry credential
if ! command -v aws >/dev/null 2>&1; then
    printf '  \e[33m!\e[0m aws CLI not installed yet — prep-host installs it; credential check deferred\n'
else
    if aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
        ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"
        if aws ecr get-authorization-token --region "$REGION" >/dev/null 2>&1; then ok "registry token OK ($REGISTRY_HOST)"; else
            fail "this AWS identity cannot get a registry token — it must be in IAM group corewaf-ecr-pull (ask the CoreWAF operators)"; fi
    else
        cat >&2 <<MSG
ERROR: no usable AWS credential in this shell.

  The rig pulls everything from the CoreWAF registry (AWS ECR). You need an access
  key for an IAM user in group corewaf-ecr-pull, issued by the CoreWAF operators:

    aws configure --profile corewaf-ecr      # paste the key; region ${REGION}
    export AWS_PROFILE=corewaf-ecr
    # then re-run this bootstrap
MSG
        exit 1
    fi
fi

# ── fetch the rig
step "Fetching ${REPO_URL} (${REF}) → ${DIR}"
if [[ -d "$DIR/.git" ]]; then
    git -C "$DIR" fetch -q origin "$REF" && git -C "$DIR" checkout -q "$REF" && git -C "$DIR" pull -q --ff-only origin "$REF"
    ok "refreshed existing clone"
elif [[ -e "$DIR" ]]; then
    fail "$DIR exists but is not a git checkout — move it aside or set COREWAF_RIG_DIR"
else
    git clone -q --branch "$REF" "$REPO_URL" "$DIR"; ok "cloned"
fi
cd "$DIR"
[[ "${NO_UP:-0}" == 1 ]] && { echo; echo "Stopped after clone (NO_UP=1). Next: cd $DIR && task prep-host && task up"; exit 0; }

# ── task (prep-host installs it if missing; bootstrap it first for the very first run)
if ! command -v task >/dev/null 2>&1; then
    step "Installing task (Taskfile runner)"
    curl -fsSL https://taskfile.dev/install.sh | sudo sh -s -- -d -b /usr/local/bin
fi

# ── prepare the host, bring the rig up
if [[ "${NO_PREP:-0}" != 1 ]]; then step "task prep-host (one sudo prompt)"; task prep-host; fi
step "task up"
exec task up
