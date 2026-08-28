#!/usr/bin/env bash
# build-kit-base.sh — build the golden image launch.sh clones from.
#
# Ensures the Alpine cloud image is cached, then runs Packer (from the
# workspace devbox) to bake the kit dependency set into
# .cache/corewaf-kit-base.qcow2. Idempotent: skips if the image already
# exists unless --force.
#
# Usage:
#   scripts/build-kit-base.sh           # build if missing
#   scripts/build-kit-base.sh --force   # rebuild from scratch
#
# Run from inside the corewaf-workspace tree so devbox puts packer on PATH.

set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/.cache"
PACKER_DIR="$ROOT/packer"

ALPINE_VER="${ALPINE_VER:-3.23.4}"
ALPINE_BRANCH="${ALPINE_VER%.*}"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/cloud/generic_alpine-${ALPINE_VER}-x86_64-bios-cloudinit-r0.qcow2"
BASE="$CACHE/alpine-${ALPINE_VER}.qcow2"

GOLDEN="${GOLDEN:-$CACHE/corewaf-rig-base.qcow2}"
OUT_DIR="$CACHE/.packer-out"   # transient; promoted to $GOLDEN on success

mkdir -p "$CACHE"

if [[ -f "$GOLDEN" && $FORCE -eq 0 ]]; then
  echo ">> golden image present: $GOLDEN (use --force to rebuild)"
  exit 0
fi

command -v packer >/dev/null 2>&1 || {
  echo "error: packer not on PATH — run inside the workspace devbox (e.g. 'devbox shell' / direnv-allowed dir)" >&2
  exit 1
}

if [[ ! -f "$BASE" ]]; then
  echo ">> downloading Alpine ${ALPINE_VER} cloud image (~175M, one-time)..."
  curl -fL --progress-bar -o "$BASE.part" "$ALPINE_URL"
  mv "$BASE.part" "$BASE"
fi

# Packer refuses to write into an existing output_directory.
rm -rf "$OUT_DIR"

echo ">> building golden image with Packer (~3 min)..."
(
  cd "$PACKER_DIR"
  packer init corewaf-kit-base.pkr.hcl
  packer build \
    -var "base_image=$BASE" \
    -var "iso_checksum=${ALPINE_SHA256:+sha256:}${ALPINE_SHA256:-none}" \
    -var "accelerator=${PACKER_ACCEL:-kvm}" \
    -var "output_dir=$OUT_DIR" \
    corewaf-kit-base.pkr.hcl
)

# Promote atomically, then drop the transient build dir.
mv -f "$OUT_DIR/corewaf-rig-base.qcow2" "$GOLDEN"
( cd "$(dirname "$GOLDEN")" && sha256sum "$(basename "$GOLDEN")" > "$(basename "$GOLDEN").sha256" )
rm -rf "$OUT_DIR"

echo ">> built $GOLDEN ($(du -h "$GOLDEN" | cut -f1))"
echo ">> launch.sh will clone overlays from it automatically."
