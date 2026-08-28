#!/usr/bin/env bash
# fetch-base.sh — get the VM base image the rig boots from. Order:
#   1. already in .cache/ with the expected sha256      -> done
#   2. oras pull RIG_BASE_REF from the CoreWAF registry  (any corewaf-ecr-pull user)
#   3. RIG_BASE_BUILD=1: build locally with packer (developer fallback)
# Pins live in images.env (RIG_BASE_REF, RIG_BASE_SHA256).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; RIG_DIR="$HERE"
# shellcheck disable=SC1091
source "$HERE/lib/registry.sh"
CACHE="$HERE/.cache"; LINK="$CACHE/corewaf-rig-base.qcow2"; mkdir -p "$CACHE"
REF="$(reg_var RIG_BASE_REF)"; SHA="$(reg_var RIG_BASE_SHA256)"
# Generations: each pinned build lives in its own file (running VM overlays point
# at the real file, so an older generation must never be deleted or renamed while
# VMs exist); the stable name is a symlink to the pinned one.
GEN="${REF##*:}"; IMG="$CACHE/corewaf-rig-base-${GEN:-local}.qcow2"
ok_sha() { [[ -s "$IMG" ]] && { [[ -z "$SHA" ]] || echo "$SHA  $IMG" | sha256sum -c --quiet - 2>/dev/null; }; }
finish() { ln -sfn "$(basename "$IMG")" "$LINK"; echo "[base] $LINK -> $(basename "$IMG")"; }
if ok_sha; then echo "[base] $IMG present (sha ok)"; finish; exit 0; fi
if [[ "${RIG_BASE_BUILD:-0}" == 1 || -z "$REF" ]]; then
    echo "[base] building locally with packer"; GOLDEN="$IMG" "$HERE/scripts/build-kit-base.sh" --force; finish; exit 0
fi
command -v oras >/dev/null || { echo "[base] oras not found — install oras (https://oras.land) or RIG_BASE_BUILD=1" >&2; exit 1; }
echo "[base] pulling $REF"
aws ecr get-login-password --region "$(reg_region)" | oras login --username AWS --password-stdin "$(reg_host)" >/dev/null \
    || { echo "[base] registry login failed — set AWS_PROFILE to a corewaf-ecr-pull user" >&2; exit 1; }
tmp="$(mktemp -d "$CACHE/.fetch.XXXX")"; trap 'rm -rf "$tmp"' EXIT
( cd "$tmp" && oras pull "$REF" >/dev/null )
f="$(ls "$tmp"/*.qcow2)"; got="$(sha256sum "$f" | cut -d' ' -f1)"
if [[ -n "$SHA" && "$got" != "$SHA" ]]; then echo "[base] sha256 mismatch: got $got want $SHA" >&2; exit 1; fi
mv -f "$f" "$IMG"; echo "$got  $(basename "$IMG")" > "$IMG.sha256"; echo "[base] fetched -> $IMG (sha256 $got)"; finish
