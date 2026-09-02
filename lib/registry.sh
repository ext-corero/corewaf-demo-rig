#!/usr/bin/env bash
# lib/registry.sh — registry helpers shared by the kit tooling (node/bin/kit-stage, kit-prep.sh, kit-up.sh).
# Source it; expects $RIG_DIR (repo root). Reads images.env.
#
# The demo rig pulls everything from the CoreWAF registry (ECR). The operator's
# AWS identity on the HOST (AWS_PROFILE / AWS_ACCESS_KEY_ID..., any IAM user in
# group corewaf-ecr-pull) mints a 12h registry token; VMs get it as a docker
# auth entry (root's /root/.docker/config.json). RIG_MODE=source
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
        || { echo "error: cannot mint a registry token for $(reg_host) — set AWS_PROFILE (or AWS_ACCESS_KEY_ID/SECRET) to a CoreWAF registry user (group corewaf-ecr-pull), or use RIG_MODE=source" >&2; return 1; }
    printf 'AWS:%s' "$tok" | base64 -w0
}
# Complete /root/.docker/config.json content.
reg_docker_config_json() { printf '{"auths": {"%s": {"auth": "%s"}}}\n' "$(reg_host)" "$(reg_docker_auth)"; }

# Kit images: "src:tag=>dst:tag" pairs (registry-relative src) + public ones.
reg_kit_pairs()  { reg_var KIT_IMAGES; }
reg_kit_public() { reg_var KIT_PUBLIC_IMAGES; }

# Shell snippet run INSIDE a VM (as root) to pull kit images from the registry and
# re-tag them to the names the unmodified public starter-kit compose expects.
reg_kit_pull_script() {
    local reg; reg="$(reg_registry)"
    echo 'set -e'
    for pair in $(reg_kit_pairs); do
        local src="${pair%%=>*}" dst="${pair##*=>}"
        echo "docker image inspect '$dst' >/dev/null 2>&1 || { docker pull -q '$reg/$src' && docker tag '$reg/$src' '$dst'; echo \"  $dst  <= $src\"; }"
    done
    for img in $(reg_kit_public); do
        echo "docker image inspect '$img' >/dev/null 2>&1 || docker pull -q '$img'"
    done
}
