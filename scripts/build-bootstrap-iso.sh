#!/usr/bin/env bash
# build-bootstrap-iso.sh [out.iso] — the rig's instance of the per-cloud BRIDGE code:
# translate the OCI bootstrap-artifacts image into the filesystem-attached carrier
# (an ISO, as the vSphere estate uses) for RIG_BOOTSTRAP_CARRIER=iso runs.
# Default carrier is docker-fetch (no ISO needed); this exists to exercise the bridge.
# Needs: docker (pull access to the ref), xorriso.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$HERE/images.env"; set +a
REF="${RIG_BOOTSTRAP_ARTIFACTS_REF:?RIG_BOOTSTRAP_ARTIFACTS_REF not pinned in images.env}"
OUT="${1:-$HERE/.qemu/base/rig-bootstrap.iso}"
docker pull -q "$REF" >/dev/null
CID="$(docker create "$REF" /noop)"; T="$(mktemp -d)"; trap 'docker rm -f "$CID" >/dev/null 2>&1; rm -rf "$T"' EXIT
docker export "$CID" | tar -x -C "$T"
[[ -d "$T/sysext" || -d "$T/bin" ]] || { echo "artifact image has no sysext/ or bin/" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs -quiet -V corewaf-bootstrap -o "$OUT" -J -r "$T"
echo "built $OUT ($(du -h "$OUT" | cut -f1)) from $REF"
