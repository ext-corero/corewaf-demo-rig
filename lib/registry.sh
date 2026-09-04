#!/usr/bin/env bash
# lib/registry.sh — registry helpers shared by vmlab.sh, kit-prep.sh, kit-up.sh, bundle.sh.
# Source it; expects $RIG_DIR (repo root). Reads images.env.
#
# The demo rig pulls everything from the CoreWAF registry (ECR). The operator's
# AWS identity on the HOST (AWS_PROFILE / AWS_ACCESS_KEY_ID..., any IAM user in
# group corewaf-ecr-pull) mints a 12h registry token; VMs get it as a docker
# auth entry (root's /root/.docker/config.json). RIG_MODE=source / RIG_BUNDLE=1
# need no registry access at all.

reg_images_env() { echo "${RIG_DIR:?}/images.env"; }
reg_var() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$(reg_images_env)" | head -1; }
reg_registry() { reg_var RIG_REGISTRY; }                       # host/prefix/ext-corero
reg_host()     { reg_registry | cut -d/ -f1; }                  # host only
reg_region()   { reg_host | sed -n 's#.*\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com#\1#p'; }

# Full registry-side ref for a rig/kit image given "waf/gui:2.0.20-abc"
reg_ref() { echo "$(reg_registry)/$1"; }

# Base64 docker auth for the registry host (AWS:<token>), or fail loudly.
reg_docker_auth() {
    local tok
    tok="$(aws ecr get-login-password --region "$(reg_region)" 2>/dev/null)" \
        || { echo "error: cannot mint a registry token for $(reg_host) — set AWS_PROFILE (or AWS_ACCESS_KEY_ID/SECRET) to a CoreWAF registry user (group corewaf-ecr-pull), or use RIG_MODE=source / RIG_BUNDLE=1" >&2; return 1; }
    printf 'AWS:%s' "$tok" | base64 -w0
}
# Complete /root/.docker/config.json content.
reg_docker_config_json() { printf '{"auths": {"%s": {"auth": "%s"}}}\n' "$(reg_host)" "$(reg_docker_auth)"; }

# Kit images: "src:tag=>dst:tag" pairs (registry-relative src) + public ones.
reg_kit_pairs()  { reg_var KIT_IMAGES; }
reg_kit_public() { reg_var KIT_PUBLIC_IMAGES; }
# Every registry-relative rig image "path:tag" from images.env (for bundle/save).
reg_rig_images() {
    local f; f="$(reg_images_env)"
    for v in $(sed -n 's/^\([A-Z_]*\)_IMAGE=.*/\1/p' "$f"); do
        local img tag; img="$(reg_var "${v}_IMAGE")"; tag="$(reg_var "${v}_TAG")"
        [[ -n "$tag" ]] && echo "$img:$tag"
    done
}
reg_public_images() { sed -n 's/^\([A-Z_]*\)_IMAGE=\([^ ]*:[^ ]*\)$/\2/p' "$(reg_images_env)"; }

# Shell snippet run INSIDE a VM (as root) to pull kit images from the registry and
# re-tag them to the names the unmodified public starter-kit compose expects.
reg_kit_pull_script() {
    local reg; reg="$(reg_registry)"
    echo 'set -e'
    # Retry transient pulls, and FAIL LOUDLY if an image cannot be staged — a
    # swallowed pull leaves the guest half-staged and only surfaces later as a
    # cryptic enrolment failure (orchestrator can't reach the private image).
    echo 'pull_retry() { for _ in 1 2 3; do docker pull -q "$1" && return 0; echo "  retry: $1" >&2; sleep 3; done; echo "  FAILED to pull $1" >&2; return 1; }'
    for pair in $(reg_kit_pairs); do
        local src="${pair%%=>*}" dst="${pair##*=>}"
        # `&&` all the way through so a failed pull propagates (set -e catches it);
        # the old trailing `; echo` always succeeded and masked the failure.
        echo "docker image inspect '$dst' >/dev/null 2>&1 || { pull_retry '$reg/$src' && docker tag '$reg/$src' '$dst' && echo \"  $dst  <= $src\"; }"
    done
    for img in $(reg_kit_public); do
        echo "docker image inspect '$img' >/dev/null 2>&1 || pull_retry '$img'"
    done
}
