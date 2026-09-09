#!/usr/bin/env bash
# next-version-ghcr.sh — GHCR mirror of next-version.sh.
#
# Usage: next-version-ghcr.sh <image> [version-file]
#   image:        e.g. ext-corero/waf/caddy-bridge
#   version-file: path to VERSION file (default: ./VERSION)
#
# Env:
#   GITHUB_TOKEN: required to read GHCR's tag list (Actions provides it
#                 automatically; locally, generate a PAT with read:packages).
#
# VERSION file contains major.minor (e.g. "0.0").
# Output: full version string (e.g. "0.0.42")
#
# Mirrors the GitLab version selector so the same VERSION + same commit
# produces the same patch number on both registries (modulo races where one
# side pushed and the other hasn't yet — drift is self-correcting on the
# next push). Anonymous reads are not always allowed for GHCR repos that
# haven't been made public yet, so we always pass the token.
set -euo pipefail

IMAGE="${1:?Usage: next-version-ghcr.sh <image> [version-file]}"
VERSION_FILE="${2:-./VERSION}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN must be set (Actions provides it automatically)}"

BASE_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "0.0")

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# GHCR's OCI distribution endpoint expects the GitHub token base64-encoded
# in the Bearer header (documented quirk — see github.com/orgs/community/discussions/26279).
TOKEN_B64=$(printf '%s' "$TOKEN" | base64 -w0 2>/dev/null || printf '%s' "$TOKEN" | base64)
HTTP=$(curl -sk -o "$TMP" -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN_B64}" \
  -H "Accept: application/json" \
  "https://ghcr.io/v2/${IMAGE}/tags/list?n=200")

case "$HTTP" in
  200) TAGS=$(jq -r '.tags[]? // empty' "$TMP") ;;
  404) TAGS="" ;;
  *)
    echo "FATAL: GHCR returned HTTP ${HTTP} for tag list of ${IMAGE}" >&2
    cat "$TMP" >&2
    exit 1
    ;;
esac

LAST_BUILD=$(
  printf '%s\n' "$TAGS" \
    | grep -E "^${BASE_VERSION//./\\.}\.[0-9]+$" \
    | sort -t. -k3 -n \
    | tail -1 \
    | awk -F. '{print $NF}' \
  || true
)

if [ -z "$LAST_BUILD" ]; then
  NEXT_BUILD=0
else
  NEXT_BUILD=$(( LAST_BUILD + 1 ))
fi

echo "${BASE_VERSION}.${NEXT_BUILD}"
