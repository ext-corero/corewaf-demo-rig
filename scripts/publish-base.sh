#!/usr/bin/env bash
# publish-base.sh — push the built base image to the CoreWAF registry as an OCI artifact.
#   <registry>/io.corewaf.ghcr/rig/base-image:<tag>   (+ :latest)
# Needs a push-capable AWS identity (CI: github-user). Usage: publish-base.sh <tag> [qcow2]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; RIG_DIR="$HERE"
# shellcheck disable=SC1091
source "$HERE/lib/registry.sh"
TAG="${1:?usage: publish-base.sh <tag> [qcow2]}"
IMG="${2:-$HERE/.cache/corewaf-rig-base.qcow2}"
REPO="$(reg_host)/io.corewaf.ghcr/rig/base-image"
[[ -s "$IMG" ]] || { echo "no image at $IMG" >&2; exit 1; }
[[ -s "$IMG.sha256" ]] || ( cd "$(dirname "$IMG")" && sha256sum "$(basename "$IMG")" > "$(basename "$IMG").sha256" )
aws ecr describe-repositories --repository-names io.corewaf.ghcr/rig/base-image --region "$(reg_region)" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name io.corewaf.ghcr/rig/base-image --region "$(reg_region)" >/dev/null
aws ecr get-login-password --region "$(reg_region)" | oras login --username AWS --password-stdin "$(reg_host)" >/dev/null
cd "$(dirname "$IMG")"
oras push "$REPO:$TAG,latest" \
  --artifact-type application/vnd.corewaf.rig.base-image \
  --annotation "org.opencontainers.image.created=$(date -u +%FT%TZ)" \
  "$(basename "$IMG"):application/vnd.corewaf.rig.base-image.qcow2" \
  "$(basename "$IMG").sha256:text/plain"
echo "published $REPO:$TAG (+latest)  sha256=$(cut -d' ' -f1 "$(basename "$IMG").sha256")"
